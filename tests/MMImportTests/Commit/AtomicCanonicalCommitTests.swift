import CSQLite
import Foundation
import LedgerCore
import Testing

@testable import MMImport

/// v12 tables, children first, so tests can rebuild an older store shape.
private let v12AnnotationTables = [
  "ledger_revision_tag", "ledger_template_tag", "ledger_transaction_template", "ledger_memo",
  "ledger_tag",
]

@Suite("Atomic idempotent canonical commit")
struct AtomicCanonicalCommitTests {
  @Test("first commit persists once and an identical retry is unchanged")
  func firstCommitAndRetry() throws {
    try withCommitDirectory { directory in
      let fixture = try makeFixture(directory: directory, variant: .first)
      let committer = SQLiteCanonicalCommitter()
      let first = try committer.commit(fixture.request)
      let retry = try committer.commit(fixture.request)

      #expect(first.status == .committed)
      #expect(retry.status == .unchanged)
      #expect(first.canonicalChecksum == retry.canonicalChecksum)
      #expect(try committer.eventCount(at: fixture.request.canonicalDatabaseURL) == 1)
      #expect(first.proofs.count == 1)
      #expect(first.proofs == retry.proofs)
      #expect(!first.humanDescription.contains(fixture.privateSentinel))
    }
  }

  @Test("a receipt-bearing v8 canonical store upgrades atomically on an unchanged retry")
  func legacyV8RetryMigratesToV9() throws {
    try withCommitDirectory { directory in
      let fixture = try makeFixture(directory: directory, variant: .first)
      let committer = SQLiteCanonicalCommitter()
      _ = try committer.commit(fixture.request)
      try withDatabase(fixture.request.canonicalDatabaseURL) { database in
        for trigger in [
          "ledger_transaction_revision_immutable_update",
          "ledger_transaction_revision_immutable_delete",
          "ledger_transaction_effect_immutable_update",
          "ledger_transaction_effect_immutable_delete",
          "ledger_transaction_source_literal_immutable_update",
          "ledger_transaction_source_literal_immutable_delete",
          "ledger_transaction_link_immutable_update",
          "ledger_transaction_link_immutable_delete",
        ] {
          try executeTestSQL(database, "DROP TRIGGER \(trigger)")
        }
        for table in v12AnnotationTables + [
          "ledger_account_preferences", "ledger_account_group", "ledger_category_tree",
          "ledger_receipt_trust_anchor",
          "ledger_transaction_link", "ledger_transaction_source_literal",
          "ledger_transaction_effect", "ledger_transaction_revision", "ledger_transaction",
          "ledger_category", "ledger_account", "ledger_origin", "ledger_budget",
          "ledger_recurrence_rule", "ledger_installment_plan",
        ] {
          try executeTestSQL(database, "DROP TABLE \(table)")
        }
        try executeTestSQL(
          database,
          "UPDATE ledger_meta SET value='8' WHERE key='schema_version'; UPDATE ledger_meta SET value='\(CanonicalLedgerSchema.legacyV8Fingerprint)' WHERE key='schema_fingerprint'"
        )
      }

      let retry = try committer.commit(fixture.request)
      #expect(retry.status == .unchanged)
      #expect(try committer.eventCount(at: fixture.request.canonicalDatabaseURL) == 1)
      try withDatabase(fixture.request.canonicalDatabaseURL) { database in
        let version = try scalarTestText(
          database, "SELECT value FROM ledger_meta WHERE key='schema_version'")
        let fingerprint = try scalarTestText(
          database, "SELECT value FROM ledger_meta WHERE key='schema_fingerprint'")
        #expect(version == String(CanonicalLedgerSchema.version))
        #expect(fingerprint == CanonicalLedgerSchema.fingerprint)
      }
    }
  }

  @Test("an exact v10 canonical store extends atomically through the current schema")
  func exactV10MigratesToV11() throws {
    try withCommitDirectory { directory in
      let fixture = try makeFixture(directory: directory, variant: .first)
      let committer = SQLiteCanonicalCommitter()
      _ = try committer.commit(fixture.request)
      try withDatabase(fixture.request.canonicalDatabaseURL) { database in
        for table in v12AnnotationTables + [
          "ledger_account_preferences", "ledger_account_group", "ledger_category_tree",
          "ledger_receipt_trust_anchor",
        ] {
          try executeTestSQL(database, "DROP TABLE \(table)")
        }
        try executeTestSQL(
          database,
          "UPDATE ledger_meta SET value='10' WHERE key='schema_version'; UPDATE ledger_meta SET value='\(CanonicalLedgerSchema.legacyV10Fingerprint)' WHERE key='schema_fingerprint'"
        )
      }

      let retry = try committer.commit(fixture.request)
      #expect(retry.status == .unchanged)
      try withDatabase(fixture.request.canonicalDatabaseURL) { database in
        let version = try scalarTestText(
          database, "SELECT value FROM ledger_meta WHERE key='schema_version'")
        let fingerprint = try scalarTestText(
          database, "SELECT value FROM ledger_meta WHERE key='schema_fingerprint'")
        let foundationCount = try scalarTestText(
          database,
          "SELECT CAST(count(*) AS TEXT) FROM sqlite_schema WHERE type='table' AND name IN ('ledger_category_tree','ledger_account_group','ledger_account_preferences')"
        )
        #expect(version == String(CanonicalLedgerSchema.version))
        #expect(fingerprint == CanonicalLedgerSchema.fingerprint)
        #expect(foundationCount == "3")
      }
    }
  }

  @Test("an exact v11 canonical store gains the v12 annotation tables on retry")
  func exactV11MigratesToV12() throws {
    try withCommitDirectory { directory in
      let fixture = try makeFixture(directory: directory, variant: .first)
      let committer = SQLiteCanonicalCommitter()
      _ = try committer.commit(fixture.request)
      try withDatabase(fixture.request.canonicalDatabaseURL) { database in
        for table in v12AnnotationTables {
          try executeTestSQL(database, "DROP TABLE \(table)")
        }
        try executeTestSQL(
          database,
          "UPDATE ledger_meta SET value='11' WHERE key='schema_version'; UPDATE ledger_meta SET value='\(CanonicalLedgerSchema.legacyV11Fingerprint)' WHERE key='schema_fingerprint'"
        )
      }

      let retry = try committer.commit(fixture.request)
      #expect(retry.status == .unchanged)
      #expect(try committer.eventCount(at: fixture.request.canonicalDatabaseURL) == 1)
      try withDatabase(fixture.request.canonicalDatabaseURL) { database in
        let version = try scalarTestText(
          database, "SELECT value FROM ledger_meta WHERE key='schema_version'")
        let annotationCount = try scalarTestText(
          database,
          "SELECT CAST(count(*) AS TEXT) FROM sqlite_schema WHERE type='table' AND name IN ('ledger_tag','ledger_revision_tag','ledger_transaction_template','ledger_template_tag','ledger_memo')"
        )
        #expect(version == "12")
        #expect(annotationCount == "5")
      }
    }
  }

  @Test("receipt membership scopes retries to their own committed import")
  func retryAfterAnotherImportUsesScopedMembership() throws {
    try withCommitDirectory { directory in
      let first = try makeFixture(directory: directory, variant: .first)
      let second = try makeFixture(
        directory: directory, variant: .second, canonicalURL: first.request.canonicalDatabaseURL)
      let committer = SQLiteCanonicalCommitter()
      _ = try committer.commit(first.request)
      _ = try committer.commit(second.request)

      let retry = try committer.commit(first.request)
      #expect(retry.status == .unchanged)
      #expect(try committer.eventCount(at: first.request.canonicalDatabaseURL) == 2)
    }
  }

  @Test("surplus receipt membership makes the affected retry conflict")
  func retryRejectsSurplusReceiptMembership() throws {
    try withCommitDirectory { directory in
      let first = try makeFixture(directory: directory, variant: .first)
      let second = try makeFixture(
        directory: directory, variant: .second, canonicalURL: first.request.canonicalDatabaseURL)
      let committer = SQLiteCanonicalCommitter()
      _ = try committer.commit(first.request)
      _ = try committer.commit(second.request)
      try withDatabase(first.request.canonicalDatabaseURL) { database in
        try executeTestSQL(
          database,
          "INSERT INTO receipt_binding SELECT e.idempotency_key, b.event_id, b.semantic, b.provenance_id FROM receipt_event e, receipt_binding b WHERE e.event_id != b.event_id LIMIT 1"
        )
      }

      var conflicts = 0
      for request in [first.request, second.request] {
        do { _ = try committer.commit(request) } catch CanonicalCommitError.idempotencyConflict {
          conflicts += 1
        }
      }
      #expect(conflicts == 2)
    }
  }

  @Test("orphan receipt envelopes make an unchanged retry conflict")
  func retryRejectsOrphanReceiptEnvelope() throws {
    try withCommitDirectory { directory in
      let fixture = try makeFixture(directory: directory, variant: .first)
      let committer = SQLiteCanonicalCommitter()
      _ = try committer.commit(fixture.request)
      let extra = fixtureIDs(base: "z")
      try withDatabase(fixture.request.canonicalDatabaseURL) { database in
        try executeTestSQL(
          database,
          "INSERT INTO import_receipt VALUES('\(extra[0])', '\(extra[1])', '\(extra[2])', 'synthetic-profile', 'synthetic-adapter', '\(extra[3])', '\(extra[4])', 0, 8)"
        )
      }
      #expect(throws: CanonicalCommitError.idempotencyConflict) {
        _ = try committer.commit(fixture.request)
      }
    }
  }

  @Test("destination expectation is enforced inside the write transaction")
  func destinationExpectationRejectsChangedLedgerBeforeMutation() throws {
    try withCommitDirectory { directory in
      let fixture = try makeFixture(directory: directory, variant: .first)
      let committer = SQLiteCanonicalCommitter()
      _ = try committer.commit(fixture.request)
      let before = try committer.canonicalChecksum(at: fixture.request.canonicalDatabaseURL)

      #expect(throws: CanonicalCommitError.idempotencyConflict) {
        _ = try committer.commit(
          fixture.request, expecting: .checksum(String(repeating: "0", count: 64)))
      }
      #expect(try committer.canonicalChecksum(at: fixture.request.canonicalDatabaseURL) == before)
    }
  }

  @Test("receipt binding semantics are constrained to canonical source semantics")
  func receiptBindingRejectsUnknownSemantic() throws {
    try withCommitDirectory { directory in
      let fixture = try makeFixture(directory: directory, variant: .first)
      _ = try SQLiteCanonicalCommitter().commit(fixture.request)
      try withDatabase(fixture.request.canonicalDatabaseURL) { database in
        #expect(throws: CommitTestError.sqlite) {
          try executeTestSQL(
            database,
            "INSERT INTO receipt_binding SELECT idempotency_key, event_id, char(105,110,118,97,108,105,100), provenance_id FROM receipt_binding LIMIT 1"
          )
        }
      }
    }
  }

  @Test("generic empty commit is rejected before a destination is created")
  func genericEmptyCommitIsRejected() throws {
    try withCommitDirectory { directory in
      let fixture = try makeFixture(directory: directory, variant: .first)
      let empty = CanonicalCommitRequest(
        canonicalDatabaseURL: fixture.request.canonicalDatabaseURL,
        stagingDatabaseURL: fixture.request.stagingDatabaseURL,
        expectedManifest: fixture.request.expectedManifest,
        expectedStagingDigest: fixture.request.expectedStagingDigest,
        mappingDecisions: fixture.request.mappingDecisions, events: [])

      #expect(throws: CanonicalCommitError.invalidRequest) {
        try SQLiteCanonicalCommitter().commit(empty)
      }
      #expect(!FileManager.default.fileExists(atPath: empty.canonicalDatabaseURL.path))
    }
  }

  @Test("a noncanonical staging receipt identifier is rejected before destination creation")
  func noncanonicalStagingReceiptIDIsRejected() throws {
    try withCommitDirectory { directory in
      let fixture = try makeFixture(directory: directory, variant: .noncanonicalReceipt)
      try expectPreDestinationRejection(fixture, error: .invalidRequest)
    }
  }

  @Test("a noncanonical staging table identifier is rejected before destination creation")
  func noncanonicalStagingTableIDIsRejected() throws {
    try withCommitDirectory { directory in
      let fixture = try makeFixture(directory: directory, variant: .noncanonicalTable)
      try expectPreDestinationRejection(fixture, error: .unauthenticatedStaging)
    }
  }

  @Test("a noncanonical staging record identifier is rejected before destination creation")
  func noncanonicalStagingRecordIDIsRejected() throws {
    try withCommitDirectory { directory in
      let fixture = try makeFixture(directory: directory, variant: .noncanonicalRecord)
      try expectPreDestinationRejection(fixture, error: .unauthenticatedStaging)
    }
  }

  @Test("a noncanonical staging field identifier is rejected before destination creation")
  func noncanonicalStagingFieldIDIsRejected() throws {
    try withCommitDirectory { directory in
      let fixture = try makeFixture(directory: directory, variant: .noncanonicalField)
      try expectPreDestinationRejection(fixture, error: .unauthenticatedStaging)
    }
  }

  @Test("generic prepare rejects an oversized staged zero-blob before digest materialization")
  func genericPrepareRejectsOversizedStagedPayloadBoundedly() throws {
    try withCommitDirectory { directory in
      let fixture = try makeFixture(directory: directory, variant: .first)
      try withDatabase(fixture.request.stagingDatabaseURL) { database in
        try executeTestSQL(
          database,
          "UPDATE staged_field SET payload=zeroblob(\(CanonicalCommitDigest.maximumSidecarBytes + 1)) WHERE column_name='opaque'"
        )
      }

      #expect(throws: CanonicalCommitError.unauthenticatedStaging) {
        try SQLiteCanonicalCommitter().prepare(fixture.request)
      }
      #expect(!FileManager.default.fileExists(atPath: fixture.request.canonicalDatabaseURL.path))
    }
  }

  @Test("caller proof tokens are ignored and replaced by target-bound evidence")
  func callerProofTokensAreIgnored() throws {
    try withCommitDirectory { directory in
      let fixture = try makeFixture(directory: directory, variant: .first)
      let callerTokens = Set(
        fixture.request.mappingDecisions.compactMap { $0.evidence?.targetProofToken })
      #expect(callerTokens.count == fixture.request.mappingDecisions.count)

      let result = try SQLiteCanonicalCommitter().commit(fixture.request)
      #expect(result.status == .committed)
      #expect(result.proofs.allSatisfy { !callerTokens.contains($0.proofToken) })
    }
  }

  @Test("generic requests fail closed for the observed v19 profile")
  func observedV19ProfileCannotUseCallerSelectedBindings() throws {
    try withCommitDirectory { directory in
      let fixture = try makeFixture(directory: directory, variant: .first)
      let original = fixture.request.expectedManifest
      let observed = StagingManifest(
        stagingID: original.stagingID, artifactSHA256: original.artifactSHA256,
        profileID: SourceProfile.observedAndroidV19.identifier,
        adapterVersion: "money-manager-android-v19-adapter-v1",
        tableCount: original.tableCount, recordCount: original.recordCount,
        fieldCount: original.fieldCount, opaqueByteCount: original.opaqueByteCount)
      let request = CanonicalCommitRequest(
        canonicalDatabaseURL: fixture.request.canonicalDatabaseURL,
        stagingDatabaseURL: fixture.request.stagingDatabaseURL,
        expectedManifest: observed,
        expectedStagingDigest: fixture.request.expectedStagingDigest,
        mappingDecisions: fixture.request.mappingDecisions, events: fixture.request.events)

      #expect(throws: CanonicalCommitError.invalidRequest) {
        try SQLiteCanonicalCommitter().commit(request)
      }
      #expect(!FileManager.default.fileExists(atPath: request.canonicalDatabaseURL.path))
    }
  }

  @Test("arbitrary evidence cannot certify an unsupported target")
  func arbitraryEvidenceCannotCertifyUnsupportedTarget() throws {
    try withCommitDirectory { directory in
      let fixture = try makeFixture(directory: directory, variant: .first)
      let sidecarID = fixture.request.events[0].sidecarReferences[0].sidecarID
      let forged = fixture.request.mappingDecisions.map { decision in
        guard decision.subjectID == sidecarID else { return decision }
        let forgedProof = TargetBoundReconciliationProof(
          stageDigest: fixture.request.expectedStagingDigest,
          subjectID: sidecarID, kind: .field, disposition: .mapped,
          targetComponents: ["caller-forged-target"])
        return ReconciliationDecision(
          subjectID: decision.subjectID, kind: .field, disposition: .mapped,
          reasonCode: .mappedByAdapter,
          evidence: .canonicalMapping(forgedProof))
      }
      let request = CanonicalCommitRequest(
        canonicalDatabaseURL: fixture.request.canonicalDatabaseURL,
        stagingDatabaseURL: fixture.request.stagingDatabaseURL,
        expectedManifest: fixture.request.expectedManifest,
        expectedStagingDigest: fixture.request.expectedStagingDigest,
        mappingDecisions: forged,
        events: fixture.request.events)

      #expect(throws: CanonicalCommitError.unsafeMapping) {
        try SQLiteCanonicalCommitter().commit(request)
      }
      #expect(!FileManager.default.fileExists(atPath: request.canonicalDatabaseURL.path))
    }
  }

  @Test("canonical amount must match its authenticated staged payload")
  func alteredCanonicalAmountIsRejected() throws {
    try withCommitDirectory { directory in
      let fixture = try makeFixture(directory: directory, variant: .first)
      let original = fixture.request.events[0]
      let altered = try CanonicalEconomicEvent(
        eventID: original.eventID,
        accountID: original.accountID,
        kind: original.kind,
        amount: CurrencyAmount(unitCode: original.amount.unitCode, amount: ExactDecimal("98.76")),
        occurredAt: original.occurredAt,
        sourceRecordID: original.sourceRecordID,
        amountProvenance: original.amountProvenance,
        sourceBindings: original.sourceBindings,
        sidecarReferences: original.sidecarReferences)
      let request = CanonicalCommitRequest(
        canonicalDatabaseURL: fixture.request.canonicalDatabaseURL,
        stagingDatabaseURL: fixture.request.stagingDatabaseURL,
        expectedManifest: fixture.request.expectedManifest,
        expectedStagingDigest: fixture.request.expectedStagingDigest,
        mappingDecisions: fixture.request.mappingDecisions,
        events: [altered])

      #expect(throws: CanonicalCommitError.unsafeMapping) {
        try SQLiteCanonicalCommitter().commit(request)
      }
      #expect(!FileManager.default.fileExists(atPath: request.canonicalDatabaseURL.path))
      do {
        _ = try SQLiteCanonicalCommitter().commit(request)
      } catch {
        #expect(!String(describing: error).contains(fixture.privateSentinel))
        #expect(!String(reflecting: error).contains(fixture.privateSentinel))
      }
    }
  }

  @Test("currency, time, account, and kind must match authenticated staged fields")
  func alteredCanonicalSemanticsAreRejected() throws {
    try withCommitDirectory { directory in
      let fixture = try makeFixture(directory: directory, variant: .first)
      for altered in try semanticAlterations(
        fixture.request.events[0], manifest: fixture.request.expectedManifest)
      {
        let request = CanonicalCommitRequest(
          canonicalDatabaseURL: fixture.request.canonicalDatabaseURL,
          stagingDatabaseURL: fixture.request.stagingDatabaseURL,
          expectedManifest: fixture.request.expectedManifest,
          expectedStagingDigest: fixture.request.expectedStagingDigest,
          mappingDecisions: fixture.request.mappingDecisions, events: [altered])
        #expect(throws: CanonicalCommitError.unsafeMapping) {
          try SQLiteCanonicalCommitter().commit(request)
        }
        #expect(!FileManager.default.fileExists(atPath: request.canonicalDatabaseURL.path))
      }
    }
  }

  @Test("binding storage class and declared type must match authenticated staging")
  func alteredStagedFieldMetadataIsRejected() throws {
    for mutation in [
      "UPDATE staged_field SET declared_type='NUMERIC' WHERE column_name='amount'",
      "UPDATE staged_field SET storage_class='blob' WHERE column_name='amount'",
    ] {
      try withCommitDirectory { directory in
        let fixture = try makeFixture(directory: directory, variant: .first)
        try mutateStage(fixture.request.stagingDatabaseURL, sql: mutation)
        let changed = CanonicalCommitRequest(
          canonicalDatabaseURL: fixture.request.canonicalDatabaseURL,
          stagingDatabaseURL: fixture.request.stagingDatabaseURL,
          expectedManifest: fixture.request.expectedManifest,
          expectedStagingDigest: try SQLiteStagingStore().contentDigest(
            at: fixture.request.stagingDatabaseURL),
          mappingDecisions: fixture.request.mappingDecisions,
          events: fixture.request.events)
        #expect(throws: CanonicalCommitError.unsafeMapping) {
          try SQLiteCanonicalCommitter().commit(changed)
        }
      }
    }
  }

  @Test("complete sidecar survives removal of authenticated staging")
  func sidecarRoundTripsWithoutStaging() throws {
    try withCommitDirectory { directory in
      let fixture = try makeFixture(directory: directory, variant: .first)
      let event = fixture.request.events[0]
      _ = try SQLiteCanonicalCommitter().commit(fixture.request)
      try FileManager.default.removeItem(at: fixture.request.stagingDatabaseURL)

      let sidecars = try SQLiteCanonicalCommitter().sidecars(
        at: fixture.request.canonicalDatabaseURL, eventID: event.eventID)
      let sidecar = try #require(sidecars.first)
      #expect(sidecars.count == 1)
      #expect(sidecar.payload == Data(fixture.privateSentinel.utf8))
      #expect(sidecar.storageClass == .text)
      #expect(sidecar.declaredType == "TEXT")
      #expect(sidecar.formatVersion == 1)
      #expect(sidecar.provenance.deterministicID == event.sidecarReferences[0].sidecarID)
      #expect(sidecar.provenance.locator.columnName == "opaque")
      #expect(sidecar.provenance.locator.columnOrdinal == 5)
    }
  }

  @Test("canonical store is owner-only and rejects links or permissive precreation")
  func canonicalStoreOwnershipIsPinned() throws {
    try withCommitDirectory { directory in
      let fixture = try makeFixture(directory: directory, variant: .first)
      _ = try SQLiteCanonicalCommitter().commit(fixture.request)
      let attributes = try FileManager.default.attributesOfItem(
        atPath: fixture.request.canonicalDatabaseURL.path)
      #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
    try withCommitDirectory { directory in
      let fixture = try makeFixture(directory: directory, variant: .first)
      FileManager.default.createFile(
        atPath: fixture.request.canonicalDatabaseURL.path, contents: Data(),
        attributes: [.posixPermissions: 0o644])
      #expect(throws: CanonicalCommitError.incompatibleCanonicalStore) {
        try SQLiteCanonicalCommitter().commit(fixture.request)
      }
    }
    try withCommitDirectory { directory in
      let fixture = try makeFixture(directory: directory, variant: .first)
      let target = directory.appendingPathComponent("target.sqlite")
      FileManager.default.createFile(
        atPath: target.path, contents: Data(), attributes: [.posixPermissions: 0o600])
      try FileManager.default.createSymbolicLink(
        at: fixture.request.canonicalDatabaseURL, withDestinationURL: target)
      #expect(throws: CanonicalCommitError.incompatibleCanonicalStore) {
        try SQLiteCanonicalCommitter().commit(fixture.request)
      }
    }
  }

  @Test("foreign owner-only SQLite destinations are rejected before any write-side effects")
  func incompatibleDestinationIsAuthenticatedReadOnlyBeforeWritableOpen() throws {
    try withCommitDirectory { directory in
      let fixture = try makeFixture(directory: directory, variant: .first)
      try withDatabase(fixture.request.canonicalDatabaseURL) { database in
        try executeTestSQL(database, "CREATE TABLE foreign_backup_only (value TEXT NOT NULL)")
        try executeTestSQL(database, "INSERT INTO foreign_backup_only VALUES ('synthetic')")
      }
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: fixture.request.canonicalDatabaseURL.path)
      let bytesBefore = try Data(contentsOf: fixture.request.canonicalDatabaseURL)
      let modifiedBefore =
        try FileManager.default.attributesOfItem(
          atPath: fixture.request.canonicalDatabaseURL.path)[.modificationDate] as? Date
      let siblingsBefore = try FileManager.default.contentsOfDirectory(
        atPath: directory.path
      ).sorted()

      #expect(throws: CanonicalCommitError.incompatibleCanonicalStore) {
        try SQLiteCanonicalCommitter().commit(fixture.request)
      }

      #expect(try Data(contentsOf: fixture.request.canonicalDatabaseURL) == bytesBefore)
      #expect(
        (try FileManager.default.attributesOfItem(
          atPath: fixture.request.canonicalDatabaseURL.path)[.modificationDate] as? Date)
          == modifiedBefore)
      #expect(
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
          == siblingsBefore)
    }
  }

  @Test("canonical stores with SQLite companions or WAL mode are rejected without mutation")
  func unsafeCanonicalJournalingIsRejectedBeforeWritableOpen() throws {
    for unsafeState in ["companion", "wal-mode"] {
      try withCommitDirectory { directory in
        let baseline = try makeFixture(directory: directory, variant: .first)
        let next = try makeFixture(
          directory: directory, variant: .second,
          canonicalURL: baseline.request.canonicalDatabaseURL)
        let committer = SQLiteCanonicalCommitter()
        _ = try committer.commit(baseline.request)

        if unsafeState == "companion" {
          let companion = URL(fileURLWithPath: baseline.request.canonicalDatabaseURL.path + "-wal")
          #expect(
            FileManager.default.createFile(atPath: companion.path, contents: Data("synthetic".utf8))
          )
        } else {
          try withDatabase(baseline.request.canonicalDatabaseURL) { database in
            try executeTestSQL(database, "PRAGMA journal_mode=WAL")
          }
        }

        let bytesBefore = try Data(contentsOf: baseline.request.canonicalDatabaseURL)
        let modifiedBefore =
          try FileManager.default.attributesOfItem(
            atPath: baseline.request.canonicalDatabaseURL.path)[.modificationDate] as? Date
        let siblingsBefore = try FileManager.default.contentsOfDirectory(atPath: directory.path)
          .sorted()

        #expect(throws: CanonicalCommitError.incompatibleCanonicalStore) {
          try committer.commit(next.request)
        }

        #expect(try Data(contentsOf: baseline.request.canonicalDatabaseURL) == bytesBefore)
        #expect(
          (try FileManager.default.attributesOfItem(
            atPath: baseline.request.canonicalDatabaseURL.path)[.modificationDate] as? Date)
            == modifiedBefore)
        #expect(
          try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            == siblingsBefore)
      }
    }
  }

  @Test("extra or altered schema objects and fingerprints are rejected")
  func exactSchemaIsRequired() throws {
    for mutation in [
      "CREATE VIEW attacker_view AS SELECT event_id FROM economic_event",
      "UPDATE ledger_meta SET value='forged' WHERE key='schema_fingerprint'",
      "ALTER TABLE economic_event ADD COLUMN attacker TEXT",
    ] {
      try withCommitDirectory { directory in
        let fixture = try makeFixture(directory: directory, variant: .first)
        let committer = SQLiteCanonicalCommitter()
        _ = try committer.commit(fixture.request)
        try withDatabase(fixture.request.canonicalDatabaseURL) { database in
          try executeTestSQL(database, mutation)
        }
        #expect(throws: CanonicalCommitError.incompatibleCanonicalStore) {
          try committer.canonicalChecksum(at: fixture.request.canonicalDatabaseURL)
        }
      }
    }
  }

  @Test("same import identity with changed authenticated digest conflicts")
  func changedDigestConflicts() throws {
    try withCommitDirectory { directory in
      let fixture = try makeFixture(directory: directory, variant: .first)
      let committer = SQLiteCanonicalCommitter()
      _ = try committer.commit(fixture.request)
      try mutateStageKeepingManifestValid(fixture.request.stagingDatabaseURL)
      let changed = try request(
        canonicalURL: fixture.request.canonicalDatabaseURL,
        stagingURL: fixture.request.stagingDatabaseURL,
        manifest: fixture.request.expectedManifest,
        event: fixture.request.events[0])

      #expect(throws: CanonicalCommitError.idempotencyConflict) {
        try committer.commit(changed)
      }
      #expect(try committer.eventCount(at: fixture.request.canonicalDatabaseURL) == 1)
    }
  }

  @Test("failure after an event insert rolls back every canonical change")
  func injectedFailureRollsBack() throws {
    try withCommitDirectory { directory in
      let baseline = try makeFixture(directory: directory, variant: .first)
      let second = try makeFixture(
        directory: directory, variant: .second,
        canonicalURL: baseline.request.canonicalDatabaseURL)
      let committer = SQLiteCanonicalCommitter()
      _ = try committer.commit(baseline.request)
      let checksumBefore = try committer.canonicalChecksum(
        at: baseline.request.canonicalDatabaseURL)

      #expect(throws: CanonicalCommitError.injectedFailure) {
        try SQLiteCanonicalCommitter(testingFailAfterEventInserts: 1).commit(second.request)
      }
      #expect(
        try committer.canonicalChecksum(at: baseline.request.canonicalDatabaseURL)
          == checksumBefore)
      #expect(try committer.eventCount(at: baseline.request.canonicalDatabaseURL) == 1)
    }
  }

  @Test("injected failure removes a newly created empty canonical destination")
  func injectedFailureRemovesNewDestination() throws {
    try withCommitDirectory { directory in
      let fixture = try makeFixture(directory: directory, variant: .first)
      #expect(!FileManager.default.fileExists(atPath: fixture.request.canonicalDatabaseURL.path))

      #expect(throws: CanonicalCommitError.injectedFailure) {
        try SQLiteCanonicalCommitter(testingFailAfterEventInserts: 1).commit(fixture.request)
      }
      #expect(!FileManager.default.fileExists(atPath: fixture.request.canonicalDatabaseURL.path))
    }
  }

  @Test("equivalent canonical states have deterministic checksums")
  func deterministicChecksum() throws {
    try withCommitDirectory { directory in
      let first = try makeFixture(directory: directory, variant: .first)
      let secondLedger = directory.appendingPathComponent("canonical-copy.sqlite")
      let secondRequest = CanonicalCommitRequest(
        canonicalDatabaseURL: secondLedger,
        stagingDatabaseURL: first.request.stagingDatabaseURL,
        expectedManifest: first.request.expectedManifest,
        expectedStagingDigest: first.request.expectedStagingDigest,
        mappingDecisions: first.request.mappingDecisions,
        events: first.request.events)
      let committer = SQLiteCanonicalCommitter()

      let firstResult = try committer.commit(first.request)
      let secondResult = try committer.commit(secondRequest)
      #expect(firstResult.canonicalChecksum == secondResult.canonicalChecksum)
      #expect(
        try committer.canonicalChecksum(at: first.request.canonicalDatabaseURL)
          == committer.canonicalChecksum(at: secondLedger))
    }
  }

  @Test("missing or blocked mapping decisions never reach canonical state")
  func unsafeMappingIsRejectedWithoutRawOutput() throws {
    try withCommitDirectory { directory in
      let fixture = try makeFixture(directory: directory, variant: .first)
      let unsafe = CanonicalCommitRequest(
        canonicalDatabaseURL: fixture.request.canonicalDatabaseURL,
        stagingDatabaseURL: fixture.request.stagingDatabaseURL,
        expectedManifest: fixture.request.expectedManifest,
        expectedStagingDigest: fixture.request.expectedStagingDigest,
        mappingDecisions: Array(fixture.request.mappingDecisions.dropLast()),
        events: fixture.request.events)
      do {
        _ = try SQLiteCanonicalCommitter().commit(unsafe)
        Issue.record("expected unsafe mapping rejection")
      } catch {
        let output = String(describing: error) + String(reflecting: error)
        #expect(!output.contains(fixture.privateSentinel))
        #expect(error as? CanonicalCommitError == .unsafeMapping)
      }
      #expect(!FileManager.default.fileExists(atPath: fixture.request.canonicalDatabaseURL.path))
    }
  }

  @Test("pathname swap and restore after staging authentication fails closed")
  func commitRejectsStagingPathSwapAndRestore() throws {
    try withCommitDirectory { directory in
      let fixture = try makeFixture(directory: directory, variant: .first)
      let alternate = directory.appendingPathComponent("alternate.sqlite")
      let parked = directory.appendingPathComponent("parked.sqlite")
      try FileManager.default.copyItem(at: fixture.request.stagingDatabaseURL, to: alternate)
      let committer = SQLiteCanonicalCommitter(testingBeforeCanonicalOpen: {
        try! FileManager.default.moveItem(at: fixture.request.stagingDatabaseURL, to: parked)
        try! FileManager.default.moveItem(at: alternate, to: fixture.request.stagingDatabaseURL)
        try! FileManager.default.moveItem(at: fixture.request.stagingDatabaseURL, to: alternate)
        try! FileManager.default.moveItem(at: parked, to: fixture.request.stagingDatabaseURL)
      })

      #expect(throws: CanonicalCommitError.unauthenticatedStaging) {
        try committer.commit(fixture.request)
      }
      #expect(!FileManager.default.fileExists(atPath: fixture.request.canonicalDatabaseURL.path))
    }
  }

  @Test("canonical destination pathname swap after open fails closed")
  func commitRejectsCanonicalPathSwapAfterOpen() throws {
    try withCommitDirectory { directory in
      let fixture = try makeFixture(directory: directory, variant: .first)
      let parked = directory.appendingPathComponent("parked-canonical.sqlite")
      let committer = SQLiteCanonicalCommitter(testingAfterCanonicalOpen: {
        try! FileManager.default.moveItem(at: fixture.request.canonicalDatabaseURL, to: parked)
        FileManager.default.createFile(
          atPath: fixture.request.canonicalDatabaseURL.path, contents: Data(),
          attributes: [.posixPermissions: 0o600])
      })

      #expect(throws: CanonicalCommitError.incompatibleCanonicalStore) {
        try committer.commit(fixture.request)
      }
      #expect(FileManager.default.fileExists(atPath: fixture.request.canonicalDatabaseURL.path))
      #expect(FileManager.default.fileExists(atPath: parked.path))
    }
  }

  @Test("canonical creation retains its exclusive descriptor until SQLite opens")
  func commitRejectsCanonicalSwapAfterExclusiveCreate() throws {
    try withCommitDirectory { directory in
      let fixture = try makeFixture(directory: directory, variant: .first)
      let parked = directory.appendingPathComponent("parked-created.sqlite")
      let committer = SQLiteCanonicalCommitter(testingAfterCanonicalCreate: {
        try! FileManager.default.moveItem(at: fixture.request.canonicalDatabaseURL, to: parked)
        FileManager.default.createFile(
          atPath: fixture.request.canonicalDatabaseURL.path, contents: Data(),
          attributes: [.posixPermissions: 0o600])
      })

      #expect(throws: CanonicalCommitError.incompatibleCanonicalStore) {
        try committer.commit(fixture.request)
      }
      #expect(FileManager.default.fileExists(atPath: parked.path))
    }
  }

  @Test("canonical destination swaps at commit boundaries fail closed")
  func commitRejectsCanonicalSwapAtCommitBoundaries() throws {
    for phase in [0, 1] {
      try withCommitDirectory { directory in
        let fixture = try makeFixture(directory: directory, variant: .first)
        let parked = directory.appendingPathComponent("parked-commit-\(phase).sqlite")
        let swap = { @Sendable in
          try! FileManager.default.moveItem(at: fixture.request.canonicalDatabaseURL, to: parked)
          FileManager.default.createFile(
            atPath: fixture.request.canonicalDatabaseURL.path, contents: Data(),
            attributes: [.posixPermissions: 0o600])
        }
        let committer =
          phase == 0
          ? SQLiteCanonicalCommitter(testingBeforeCommit: swap)
          : SQLiteCanonicalCommitter(testingAfterCommit: swap)

        if phase == 0 {
          #expect(throws: CanonicalCommitError.incompatibleCanonicalStore) {
            try committer.commit(fixture.request)
          }
        } else {
          let result = try committer.commit(fixture.request)
          #expect(result.status == .committed)
          #expect(FileManager.default.fileExists(atPath: parked.path))
        }
      }
    }
  }

  @Test("staging mutation at the final commit boundary fails closed")
  func commitRejectsStagingMutationAtCommitBoundary() throws {
    try withCommitDirectory { directory in
      let fixture = try makeFixture(directory: directory, variant: .first)
      let committer = SQLiteCanonicalCommitter(testingBeforeCommit: {
        try! withDatabase(fixture.request.stagingDatabaseURL) { database in
          try! executeTestSQL(
            database,
            "UPDATE staged_field SET payload=CAST('changed-stage' AS BLOB) WHERE ordinal=0")
        }
      })

      #expect(throws: CanonicalCommitError.unauthenticatedStaging) {
        try committer.commit(fixture.request)
      }
      #expect(!FileManager.default.fileExists(atPath: fixture.request.canonicalDatabaseURL.path))
    }
  }

  @Test("unchanged retry validates persisted events bindings and sidecars")
  func retryRejectsMutatedReceiptBackedState() throws {
    for mutation in [
      "UPDATE economic_event SET amount_literal='99.99'",
      "DELETE FROM event_source_binding WHERE semantic='kind'",
      "UPDATE sidecar_reference SET payload=CAST('changed' AS BLOB)",
    ] {
      try withCommitDirectory { directory in
        let fixture = try makeFixture(directory: directory, variant: .first)
        let committer = SQLiteCanonicalCommitter()
        _ = try committer.commit(fixture.request)
        try withDatabase(fixture.request.canonicalDatabaseURL) { database in
          try executeTestSQL(database, mutation)
        }

        #expect(throws: CanonicalCommitError.idempotencyConflict) {
          try committer.commit(fixture.request)
        }
      }
    }
  }

  @Test("sidecar bytes storage and provenance tampering block retries and unrelated imports")
  func sidecarIntegrityBlocksEveryImportPath() throws {
    let mutations = [
      "UPDATE sidecar_reference SET payload=zeroblob(length(payload))",
      "PRAGMA ignore_check_constraints=ON; UPDATE sidecar_reference SET storage_class='invalid'",
      "UPDATE provenance_reference SET source_column_name='forged-opaque' WHERE provenance_id=(SELECT provenance_id FROM sidecar_reference LIMIT 1)",
    ]
    for mutation in mutations {
      try withCommitDirectory { directory in
        let first = try makeFixture(directory: directory, variant: .first)
        let second = try makeFixture(
          directory: directory, variant: .second,
          canonicalURL: first.request.canonicalDatabaseURL)
        let committer = SQLiteCanonicalCommitter()
        _ = try committer.commit(first.request)
        try withDatabase(first.request.canonicalDatabaseURL) { database in
          try executeTestSQL(database, mutation)
        }
        let countsBefore = try canonicalIdentityCounts(first.request.canonicalDatabaseURL)

        #expect(throws: CanonicalCommitError.idempotencyConflict) {
          try committer.commit(first.request)
        }
        #expect(throws: CanonicalCommitError.self) {
          try committer.commit(second.request)
        }
        #expect(try canonicalIdentityCounts(first.request.canonicalDatabaseURL) == countsBefore)
      }
    }
  }

  @Test("unchanged retry rejects an additional canonical event")
  func retryRejectsAdditionalCanonicalEvent() throws {
    try withCommitDirectory { directory in
      let fixture = try makeFixture(directory: directory, variant: .first)
      let committer = SQLiteCanonicalCommitter()
      _ = try committer.commit(fixture.request)
      let extraID = String(repeating: "b", count: 62) + "ee"
      try withDatabase(fixture.request.canonicalDatabaseURL) { database in
        try executeTestSQL(
          database,
          "INSERT INTO economic_event SELECT '\(extraID)', account_id, event_kind, amount_literal, currency_unit, instant_milliseconds, local_year, local_month, local_day, local_hour, local_minute, local_second, local_millisecond, timezone_kind, timezone_value, temporal_precision, resolved_offset_seconds, source_record_id, provenance_id FROM economic_event"
        )
      }

      #expect(throws: CanonicalCommitError.idempotencyConflict) {
        try committer.commit(fixture.request)
      }
    }
  }

  @Test("unrelated imports reject malformed existing canonical state")
  func unrelatedImportRejectsMalformedExistingState() throws {
    try withCommitDirectory { directory in
      let first = try makeFixture(directory: directory, variant: .first)
      let second = try makeFixture(
        directory: directory, variant: .second, canonicalURL: first.request.canonicalDatabaseURL)
      let committer = SQLiteCanonicalCommitter()
      _ = try committer.commit(first.request)
      try withDatabase(first.request.canonicalDatabaseURL) { database in
        try executeTestSQL(database, "UPDATE economic_event SET amount_literal='1..2'")
      }

      #expect(throws: CanonicalCommitError.idempotencyConflict) {
        try committer.commit(second.request)
      }
    }
    for mutation in [
      "UPDATE economic_event SET currency_unit='usd'",
      "UPDATE economic_event SET local_hour=88",
    ] {
      try withCommitDirectory { directory in
        let first = try makeFixture(directory: directory, variant: .first)
        let second = try makeFixture(
          directory: directory, variant: .second, canonicalURL: first.request.canonicalDatabaseURL)
        let committer = SQLiteCanonicalCommitter()
        _ = try committer.commit(first.request)
        try withDatabase(first.request.canonicalDatabaseURL) { database in
          try executeTestSQL(database, mutation)
        }

        #expect(throws: CanonicalCommitError.idempotencyConflict) {
          try committer.commit(second.request)
        }
      }
    }
    try withCommitDirectory { directory in
      let first = try makeFixture(directory: directory, variant: .first)
      let second = try makeFixture(
        directory: directory, variant: .second, canonicalURL: first.request.canonicalDatabaseURL)
      let committer = SQLiteCanonicalCommitter()
      _ = try committer.commit(first.request)
      let origin = try LedgerOrigin(id: String(repeating: "a", count: 64), label: "synthetic")
      let accountID = try StableLedgerID.account(
        origin: origin, localKey: String(repeating: "b", count: 64))
      let transactionID = try StableLedgerID.transaction(
        origin: origin, localKey: String(repeating: "c", count: 64))
      let revisionID = try StableLedgerID.revision(transactionID: transactionID, revision: 1)
      try withDatabase(first.request.canonicalDatabaseURL) { database in
        try executeTestSQL(
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
      }
      #expect(throws: CanonicalCommitError.idempotencyConflict) {
        try committer.commit(second.request)
      }
    }
  }

  @Test("historical IANA labels remain valid from their stored resolved offset")
  func historicalIANAIdentifierDoesNotDependOnCurrentSystemTzdata() throws {
    try withCommitDirectory { directory in
      let first = try makeFixture(directory: directory, variant: .first)
      let second = try makeFixture(
        directory: directory, variant: .second, canonicalURL: first.request.canonicalDatabaseURL)
      let committer = SQLiteCanonicalCommitter()
      _ = try committer.commit(first.request)
      // This syntactically valid identifier is deliberately not supplied by host tzdata.
      // The test proves persisted local/UTC semantics use the stored offset, not an OS lookup.
      try withDatabase(first.request.canonicalDatabaseURL) { database in
        try executeTestSQL(
          database,
          "UPDATE economic_event SET timezone_kind='iana', timezone_value='Etc/RemovedByFutureTzdata', resolved_offset_seconds=0"
        )
      }

      // Receipt integrity notices our deliberate test mutation later in the commit path;
      // importantly, it is an idempotency conflict rather than a false schema/tzdata reject.
      #expect(throws: CanonicalCommitError.idempotencyConflict) {
        try committer.commit(second.request)
      }
    }
  }

  @Test("unrelated imports reject forged receipt hashes and cross-receipt membership")
  func unrelatedImportRejectsForgedReceiptState() throws {
    try withCommitDirectory { directory in
      let first = try makeFixture(directory: directory, variant: .first)
      let second = try makeFixture(
        directory: directory, variant: .second, canonicalURL: first.request.canonicalDatabaseURL)
      let committer = SQLiteCanonicalCommitter()
      _ = try committer.commit(first.request)
      _ = try committer.commit(second.request)
      try withDatabase(first.request.canonicalDatabaseURL) { database in
        let forgedHash = String(repeating: "f", count: 64)
        try executeTestSQL(
          database,
          "UPDATE import_receipt SET event_set_hash='\(forgedHash)' WHERE idempotency_key='\(first.request.expectedManifest.stagingID)'"
        )
      }

      #expect(throws: CanonicalCommitError.idempotencyConflict) {
        try committer.commit(first.request)
      }
    }

    try withCommitDirectory { directory in
      let first = try makeFixture(directory: directory, variant: .first)
      let second = try makeFixture(
        directory: directory, variant: .second, canonicalURL: first.request.canonicalDatabaseURL)
      let thirdDirectory = directory.appendingPathComponent("third")
      try FileManager.default.createDirectory(at: thirdDirectory, withIntermediateDirectories: true)
      let third = try makeFixture(
        directory: thirdDirectory, variant: .first,
        canonicalURL: first.request.canonicalDatabaseURL)
      let committer = SQLiteCanonicalCommitter()
      _ = try committer.commit(first.request)
      _ = try committer.commit(second.request)
      try withDatabase(first.request.canonicalDatabaseURL) { database in
        try executeTestSQL(
          database,
          "INSERT INTO receipt_binding SELECT '\(first.request.expectedManifest.stagingID)', b.event_id, b.semantic, b.provenance_id FROM receipt_binding b WHERE b.idempotency_key='\(second.request.expectedManifest.stagingID)' LIMIT 1"
        )
      }

      #expect(throws: CanonicalCommitError.idempotencyConflict) {
        try committer.commit(third.request)
      }
    }
  }
}

private enum FixtureVariant {
  case first, second, noncanonicalReceipt, noncanonicalTable, noncanonicalRecord, noncanonicalField
}

private struct CommitFixture {
  let request: CanonicalCommitRequest
  let privateSentinel: String
}

private func makeFixture(
  directory: URL,
  variant: FixtureVariant,
  canonicalURL: URL? = nil
) throws -> CommitFixture {
  let ids: [String]
  let suffix: String
  switch variant {
  case .first:
    ids = fixtureIDs(base: "a")
    suffix = "one"
  case .second:
    ids = fixtureIDs(base: "1")
    suffix = "two"
  case .noncanonicalReceipt:
    ids = fixtureIDs(
      stagingID: String(repeating: "b", count: 64),
      artifactSHA256: fixtureIDs(base: "a")[9])
    suffix = "noncanonical-receipt"
  case .noncanonicalTable:
    var forged = fixtureIDs(base: "a")
    forged[1] = String(repeating: "b", count: 64)
    ids = forged
    suffix = "noncanonical-table"
  case .noncanonicalRecord:
    var forged = fixtureIDs(base: "a")
    forged[2] = String(repeating: "b", count: 64)
    ids = forged
    suffix = "noncanonical-record"
  case .noncanonicalField:
    var forged = fixtureIDs(base: "a")
    forged[3] = String(repeating: "b", count: 64)
    ids = forged
    suffix = "noncanonical-field"
  }
  let stageURL = directory.appendingPathComponent("stage-\(suffix).sqlite")
  let ledgerURL = canonicalURL ?? directory.appendingPathComponent("canonical.sqlite")
  let sentinel = "PRIVATE_COMMIT_SENTINEL"
  let accountSource = "synthetic-account-\(suffix)"
  let occurredAt = try SourceTemporal(
    resolving: SourceLocalDateTime(
      date: SourceLocalDate(year: 2025, month: 1, day: 2), hour: 3, minute: 4),
    in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .minute)
  let payloads = [
    "12.30", "USD", temporalBindingLiteral(occurredAt), accountSource,
    CanonicalEventKind.expense.rawValue, sentinel,
  ]
  let manifest = StagingManifest(
    stagingID: ids[0], artifactSHA256: ids[9], profileID: "synthetic-profile",
    adapterVersion: "synthetic-adapter", tableCount: 1, recordCount: 1, fieldCount: 6,
    opaqueByteCount: payloads.reduce(0) { $0 + $1.utf8.count })
  try createStage(at: stageURL, manifest: manifest, ids: ids, payloads: payloads)
  let fieldNames = ["amount", "currency", "occurred_at", "account", "kind"]
  let semantics = CanonicalEventSourceSemantic.allCases
  let bindings = try zip(semantics, fieldNames.enumerated()).map { semantic, indexedName in
    try CanonicalEventSourceBinding(
      semantic: semantic,
      provenance: FieldProvenance(
        artifactSHA256: manifest.artifactSHA256, profileID: manifest.profileID,
        adapterVersion: manifest.adapterVersion,
        locator: SourceLocator(
          table: "synthetic_entries", recordKey: "synthetic-record",
          columnOrdinal: indexedName.offset, columnName: indexedName.element),
        deterministicID: ids[indexedName.offset + 3]),
      declaredType: "TEXT", storageClass: .text)
  }
  let amountBinding = try #require(bindings.first { $0.semantic == .amount })
  let event = try CanonicalEconomicEvent(
    eventID: StableCanonicalID.event(sourceRecordID: ids[2], effectOrdinal: 0),
    accountID: StableCanonicalID.account(
      profileID: manifest.profileID, sourceAccountID: accountSource),
    kind: .expense,
    amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("12.30")),
    occurredAt: occurredAt,
    sourceRecordID: ids[2],
    amountProvenance: amountBinding.provenance,
    sourceBindings: bindings,
    sidecarReferences: [
      CanonicalSidecarReference(sidecarID: ids[8], provenanceID: ids[8])
    ])
  return CommitFixture(
    request: try request(
      canonicalURL: ledgerURL, stagingURL: stageURL, manifest: manifest, event: event,
      subjectIDs: stageSubjectIDs(ids: ids)),
    privateSentinel: sentinel)
}

private func request(
  canonicalURL: URL, stagingURL: URL, manifest: StagingManifest,
  event: CanonicalEconomicEvent,
  subjectIDs: (table: String, record: String, mappedFields: [String], sidecarField: String)? = nil
) throws -> CanonicalCommitRequest {
  let digest = try SQLiteStagingStore().contentDigest(at: stagingURL)
  let ids = subjectIDs ?? stageSubjectIDs(manifest: manifest)
  let specifications:
    [(String, ReconciliationSubjectKind, ReconciliationDisposition, ReconciliationReasonCode)] =
      [
        (manifest.stagingID, .artifact, .preserved, .immutableSourceProvenance),
        (ids.table, .table, .mapped, .knownTableAdapter),
        (ids.record, .record, .mapped, .knownRecordAdapter),
      ] + ids.mappedFields.map { ($0, .field, .mapped, .mappedByAdapter) }
      + [(ids.sidecarField, .field, .preserved, .opaqueSidecarPreserved)]
  let decisions = specifications.map { specification in
    ReconciliationDecision(
      subjectID: specification.0, kind: specification.1, disposition: specification.2,
      reasonCode: specification.3,
      evidence: evidence(
        digest: digest, subjectID: specification.0, kind: specification.1,
        disposition: specification.2, proof: "caller-controlled"))
  }
  return CanonicalCommitRequest(
    canonicalDatabaseURL: canonicalURL, stagingDatabaseURL: stagingURL,
    expectedManifest: manifest, expectedStagingDigest: digest,
    mappingDecisions: decisions, events: [event])
}

private func evidence(
  digest: String, subjectID: String, kind: ReconciliationSubjectKind,
  disposition: ReconciliationDisposition, proof: String
) -> ReconciliationEvidence? {
  let targetProof = TargetBoundReconciliationProof(
    stageDigest: digest, subjectID: subjectID, kind: kind, disposition: disposition,
    targetComponents: [proof])
  return switch disposition {
  case .mapped:
    ReconciliationEvidence.canonicalMapping(targetProof)
  case .preserved:
    ReconciliationEvidence.opaquePreservation(targetProof)
  case .excluded:
    ReconciliationEvidence.intentionalExclusion(targetProof)
  case .blocked: nil
  }
}

private func stageSubjectIDs(manifest: StagingManifest) -> (
  table: String, record: String, mappedFields: [String], sidecarField: String
) {
  stageSubjectIDs(ids: fixtureIDs(artifactSHA256: manifest.artifactSHA256))
}

private func stageSubjectIDs(ids: [String]) -> (
  table: String, record: String, mappedFields: [String], sidecarField: String
) {
  return (ids[1], ids[2], Array(ids[3...7]), ids[8])
}

private func createStage(
  at url: URL, manifest: StagingManifest, ids: [String], payloads: [String]
) throws {
  try withDatabase(url) { database in
    let statements = [
      "CREATE TABLE staging_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)",
      "CREATE TABLE staged_artifact(artifact_id TEXT PRIMARY KEY, artifact_sha256 TEXT NOT NULL, profile_id TEXT NOT NULL, adapter_version TEXT NOT NULL, source_size_bytes INTEGER NOT NULL CHECK(source_size_bytes >= 0))",
      "CREATE TABLE staged_table(table_id TEXT PRIMARY KEY, artifact_id TEXT NOT NULL REFERENCES staged_artifact(artifact_id), ordinal INTEGER NOT NULL CHECK(ordinal >= 0), table_name TEXT NOT NULL, record_count INTEGER NOT NULL CHECK(record_count >= 0), UNIQUE(artifact_id, ordinal), UNIQUE(artifact_id, table_name))",
      "CREATE TABLE staged_record(record_id TEXT PRIMARY KEY, table_id TEXT NOT NULL REFERENCES staged_table(table_id), record_key TEXT NOT NULL, field_count INTEGER NOT NULL CHECK(field_count >= 0), opaque_byte_count INTEGER NOT NULL CHECK(opaque_byte_count >= 0), UNIQUE(table_id, record_key))",
      "CREATE TABLE staged_field(field_id TEXT PRIMARY KEY, record_id TEXT NOT NULL REFERENCES staged_record(record_id), ordinal INTEGER NOT NULL CHECK(ordinal >= 0), column_name TEXT NOT NULL, declared_type TEXT, storage_class TEXT NOT NULL CHECK(storage_class IN ('null', 'integer', 'real', 'blob', 'text')), payload BLOB NOT NULL, sidecar_version INTEGER NOT NULL CHECK(sidecar_version = 1), container_member TEXT, UNIQUE(record_id, ordinal))",
      "CREATE TABLE staging_manifest(format_version INTEGER NOT NULL CHECK(format_version = 1), staging_id TEXT PRIMARY KEY REFERENCES staged_artifact(artifact_id), artifact_sha256 TEXT NOT NULL, profile_id TEXT NOT NULL, adapter_version TEXT NOT NULL, table_count INTEGER NOT NULL CHECK(table_count >= 0), record_count INTEGER NOT NULL CHECK(record_count >= 0), field_count INTEGER NOT NULL CHECK(field_count >= 0), opaque_byte_count INTEGER NOT NULL CHECK(opaque_byte_count >= 0))",
      "INSERT INTO staging_meta VALUES('format_version', '1')",
      "INSERT INTO staging_meta VALUES('staging_id', '\(manifest.stagingID)')",
      "INSERT INTO staging_meta VALUES('limits_description', 'synthetic-limits-v1')",
      "INSERT INTO staged_artifact VALUES('\(ids[0])', '\(ids[9])', 'synthetic-profile', 'synthetic-adapter', 1)",
      "INSERT INTO staged_table VALUES('\(ids[1])', '\(ids[0])', 0, 'synthetic_entries', 1)",
      "INSERT INTO staged_record VALUES('\(ids[2])', '\(ids[1])', 'synthetic-record', 6, \(manifest.opaqueByteCount))",
      "INSERT INTO staged_field VALUES('\(ids[3])', '\(ids[2])', 0, 'amount', 'TEXT', 'text', CAST('\(payloads[0])' AS BLOB), 1, NULL)",
      "INSERT INTO staged_field VALUES('\(ids[4])', '\(ids[2])', 1, 'currency', 'TEXT', 'text', CAST('\(payloads[1])' AS BLOB), 1, NULL)",
      "INSERT INTO staged_field VALUES('\(ids[5])', '\(ids[2])', 2, 'occurred_at', 'TEXT', 'text', CAST('\(payloads[2])' AS BLOB), 1, NULL)",
      "INSERT INTO staged_field VALUES('\(ids[6])', '\(ids[2])', 3, 'account', 'TEXT', 'text', CAST('\(payloads[3])' AS BLOB), 1, NULL)",
      "INSERT INTO staged_field VALUES('\(ids[7])', '\(ids[2])', 4, 'kind', 'TEXT', 'text', CAST('\(payloads[4])' AS BLOB), 1, NULL)",
      "INSERT INTO staged_field VALUES('\(ids[8])', '\(ids[2])', 5, 'opaque', 'TEXT', 'text', CAST('\(payloads[5])' AS BLOB), 1, NULL)",
      "INSERT INTO staging_manifest VALUES(1, '\(ids[0])', '\(ids[9])', 'synthetic-profile', 'synthetic-adapter', 1, 1, 6, \(manifest.opaqueByteCount))",
    ]
    for statement in statements { try executeTestSQL(database, statement) }
  }
  try rewriteStageDigest(at: url)
}

private func mutateStageKeepingManifestValid(_ url: URL) throws {
  try withDatabase(url) { database in
    try executeTestSQL(
      database,
      "UPDATE staged_field SET payload=CAST('XRIVATE_COMMIT_SENTINEL' AS BLOB) WHERE column_name='opaque'"
    )
    try executeTestSQL(database, "DELETE FROM staging_meta WHERE key='content_digest'")
  }
  try rewriteStageDigest(at: url)
}

private func rewriteStageDigest(at url: URL) throws {
  let digest = try SQLiteStagingStore().contentDigest(at: url)
  try withDatabase(url) { database in
    try executeTestSQL(
      database, "INSERT INTO staging_meta VALUES('content_digest', '\(digest)')")
  }
}

private func mutateStage(_ url: URL, sql: String) throws {
  try withDatabase(url) { database in
    try executeTestSQL(database, sql)
    try executeTestSQL(database, "DELETE FROM staging_meta WHERE key='content_digest'")
  }
  try rewriteStageDigest(at: url)
}

private func withDatabase(_ url: URL, _ body: (OpaquePointer) throws -> Void) throws {
  var database: OpaquePointer?
  guard
    sqlite3_open_v2(
      url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
    let database
  else { throw CommitTestError.sqlite }
  defer { sqlite3_close(database) }
  try body(database)
}

private func executeTestSQL(_ database: OpaquePointer, _ sql: String) throws {
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
    throw CommitTestError.sqlite
  }
}

private func scalarTestText(_ database: OpaquePointer, _ sql: String) throws -> String? {
  var statement: OpaquePointer?
  guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
    throw CommitTestError.sqlite
  }
  defer { sqlite3_finalize(statement) }
  guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
  guard let text = sqlite3_column_text(statement, 0) else { return nil }
  return String(
    data: Data(bytes: text, count: Int(sqlite3_column_bytes(statement, 0))), encoding: .utf8)
}

private func canonicalIdentityCounts(_ url: URL) throws -> [Int] {
  var counts: [Int] = []
  try withDatabase(url) { database in
    for table in ["economic_event", "import_receipt"] {
      var statement: OpaquePointer?
      guard
        sqlite3_prepare_v2(database, "SELECT count(*) FROM \(table)", -1, &statement, nil)
          == SQLITE_OK, let statement
      else { throw CommitTestError.sqlite }
      defer { sqlite3_finalize(statement) }
      guard sqlite3_step(statement) == SQLITE_ROW else { throw CommitTestError.sqlite }
      counts.append(Int(sqlite3_column_int64(statement, 0)))
    }
  }
  return counts
}

private func withCommitDirectory(_ body: (URL) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "ledger-atlas-commit-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try body(directory)
}

private func fixtureIDs(base: Character) -> [String] {
  guard base == "a" || base == "1" else {
    return (0..<10).map { index in
      String(repeating: String(base), count: 62) + String(format: "%02x", index)
    }
  }
  let artifactSHA256 = String(repeating: String(base), count: 62) + "09"
  return fixtureIDs(artifactSHA256: artifactSHA256)
}

private func fixtureIDs(artifactSHA256: String) -> [String] {
  let stagingID = StableStagingID.stage(
    artifactSHA256: artifactSHA256, profileID: "synthetic-profile",
    adapterVersion: "synthetic-adapter")
  return fixtureIDs(stagingID: stagingID, artifactSHA256: artifactSHA256)
}

private func fixtureIDs(stagingID: String, artifactSHA256: String) -> [String] {
  let tableID = StableStagingID.table(stagingID: stagingID, table: "synthetic_entries")
  let recordID = StableStagingID.record(
    stagingID: stagingID, table: "synthetic_entries", recordKey: "synthetic-record")
  let fields = ["amount", "currency", "occurred_at", "account", "kind", "opaque"]
    .enumerated().map { index, name in
      StableStagingID.field(
        stagingID: stagingID,
        locator: SourceLocator(
          table: "synthetic_entries", recordKey: "synthetic-record", columnOrdinal: index,
          columnName: name))
    }
  return [stagingID, tableID, recordID] + fields + [artifactSHA256]
}

private final class CommitBoundaryProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var reached = false

  func markReached() { lock.withLock { reached = true } }
  var wasReached: Bool { lock.withLock { reached } }
}

private func expectPreDestinationRejection(
  _ fixture: CommitFixture, error: CanonicalCommitError
) throws {
  let probe = CommitBoundaryProbe()
  let committer = SQLiteCanonicalCommitter(testingBeforeCanonicalOpen: probe.markReached)
  #expect(throws: error) { try committer.commit(fixture.request) }
  #expect(!probe.wasReached)
  #expect(!FileManager.default.fileExists(atPath: fixture.request.canonicalDatabaseURL.path))
}

private func temporalBindingLiteral(_ value: SourceTemporal) -> String {
  let zone =
    value.timeZone.ianaIdentifier.map { "iana:\($0)" }
    ?? "fixed:\(value.timeZone.fixedOffsetSeconds!)"
  let date = value.localDateTime.date
  return [
    String(value.instant.epochMilliseconds), String(date.year), String(date.month),
    String(date.day), String(value.localDateTime.hour), String(value.localDateTime.minute),
    String(value.localDateTime.second), String(value.localDateTime.millisecond), zone,
    value.precision.rawValue, String(value.resolvedOffsetSeconds),
  ].joined(separator: "|")
}

private func semanticAlterations(
  _ original: CanonicalEconomicEvent, manifest: StagingManifest
) throws -> [CanonicalEconomicEvent] {
  let alteredTime = try SourceTemporal(
    resolving: SourceLocalDateTime(
      date: SourceLocalDate(year: 2025, month: 1, day: 3), hour: 3, minute: 4),
    in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .minute)
  func event(
    accountID: String? = nil, kind: CanonicalEventKind? = nil,
    amount: CurrencyAmount? = nil, occurredAt: SourceTemporal? = nil
  ) throws -> CanonicalEconomicEvent {
    try CanonicalEconomicEvent(
      eventID: original.eventID, accountID: accountID ?? original.accountID,
      kind: kind ?? original.kind, amount: amount ?? original.amount,
      occurredAt: occurredAt ?? original.occurredAt,
      sourceRecordID: original.sourceRecordID, amountProvenance: original.amountProvenance,
      sourceBindings: original.sourceBindings, sidecarReferences: original.sidecarReferences)
  }
  return [
    try event(amount: CurrencyAmount(unitCode: "EUR", amount: original.amount.amount)),
    try event(occurredAt: alteredTime),
    try event(
      accountID: StableCanonicalID.account(
        profileID: manifest.profileID, sourceAccountID: "different-account")),
    try event(kind: .income),
  ]
}

private enum CommitTestError: Error { case sqlite }
