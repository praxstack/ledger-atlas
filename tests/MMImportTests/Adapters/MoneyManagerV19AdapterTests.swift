import CSQLite
import CryptoKit
import Darwin
import Foundation
import LedgerCore
import Testing

@testable import MMImport

@Test func observedV19SchemaInventoryIsCompleteAndDistinctFromSyntheticSubset() {
  #expect(MoneyManagerV19ObservedSchema.tableNames.count == 19)
  #expect(MoneyManagerV19ObservedSchema.tableNames.contains("PHOTO"))
  #expect(MoneyManagerV19ObservedSchema.tableNames.contains("REPEATTRANSACTION"))
  #expect(MoneyManagerV19ObservedSchema.tableNames.contains("INOUTCOME"))
  #expect(Set(MoneyManagerV19ObservedSchema.tableNames).count == 19)
  #expect(
    MoneyManagerV19ObservedSchema.inventory(tableNames: MoneyManagerV19ObservedSchema.tableNames)
      == MoneyManagerV19ObservedSchema.tableNames.sorted())
  #expect(SourceProfile.observedAndroidV19.identifier != MoneyManagerV19Adapter.observedProfileID)
}

@Suite("Money Manager Android v19 adapter")
struct MoneyManagerV19AdapterTests {
  @Test("free arrays cannot produce a v19 plan")
  func rejectsFreelySuppliedRecords() throws {
    let manifest = StagingManifest(
      stagingID: id(0), artifactSHA256: id(1),
      profileID: MoneyManagerV19Adapter.observedProfileID,
      adapterVersion: MoneyManagerV19Adapter.version,
      tableCount: 4, recordCount: 6, fieldCount: 18, opaqueByteCount: 0)
    #expect(throws: MoneyManagerV19AdapterError.invalidStagingInventory) {
      _ = try MoneyManagerV19Adapter.prepare(
        .init(
          manifest: manifest, stagingDigest: id(2),
          assets: [try record("ASSETS", 3, ["UID": "synthetic-account"])],
          categories: [try record("ZCATEGORY", 4, ["UID": "synthetic-category"])],
          currencies: [try record("CURRENCY", 5, ["ISO": "USD"])],
          transactions: [
            try transaction(6, type: "0", amount: "12.30"),
            try transaction(7, type: "3", amount: "18.00"),
            try transaction(8, type: "7", amount: "21.00"),
          ]))
    }
  }

  @Test("array input stays rejected even when a raw SQLite value is non-text")
  func rejectsNonTextArrayInput() throws {
    var fields = try transaction(9, type: "1", amount: "7.00").fields
    let index = try #require(fields.firstIndex { $0.name == "DO_TYPE" })
    fields[index] = try field("DO_TYPE", "1", 30, storageClass: .integer)
    let transaction = try MoneyManagerV19SourceRecord(
      tableName: "INOUTCOME", sourceRecordID: id(9), fields: fields)
    #expect(throws: MoneyManagerV19AdapterError.invalidStagingInventory) {
      _ = try MoneyManagerV19Adapter.prepare(
        .init(
          manifest: manifest(), stagingDigest: id(2), assets: [], categories: [], currencies: [],
          transactions: [transaction]))
    }
  }

  @Test("authenticated staged records bind manifest digest provenance and currency UID")
  func projectsAuthenticatedSyntheticStage() throws {
    let staged = try makeAuthenticatedStage()
    defer { try? FileManager.default.removeItem(at: staged.url) }
    let plan = try MoneyManagerV19Adapter.prepare(
      stagingDatabaseURL: staged.url, expectedManifest: staged.manifest,
      expectedContentDigest: staged.digest)
    #expect(plan.mappedEvents.count == 1)
    #expect(plan.mappedEvents[0].account.value == "synthetic-asset")
    #expect(plan.mappedEvents[0].currency.value == "USD")
    #expect(plan.mappedEvents[0].timestamp.localEpochMilliseconds == 1_738_547_200_000)
    #expect(throws: MoneyManagerV19AdapterError.invalidStagingInventory) {
      _ = try MoneyManagerV19Adapter.prepare(
        stagingDatabaseURL: staged.url, expectedManifest: staged.manifest,
        expectedContentDigest: id(9))
    }
  }

  @Test("authenticated text-safe stage keeps event and receipt-owned preservation separate")
  func commitsAuthenticatedSyntheticStageIdempotently() throws {
    let staged = try makeAuthenticatedStage()
    let canonical = FileManager.default.temporaryDirectory.appendingPathComponent(
      "v19-canonical-\(UUID().uuidString).sqlite")
    defer {
      try? FileManager.default.removeItem(at: staged.url)
      try? FileManager.default.removeItem(at: canonical)
    }
    let zone = try SourceTimeZone(fixedOffsetSeconds: 19_800)
    let request = try MoneyManagerV19Adapter.canonicalCommitRequest(
      canonicalDatabaseURL: canonical, stagingDatabaseURL: staged.url,
      expectedManifest: staged.manifest, expectedContentDigest: staged.digest,
      sourceTimeZone: zone)
    let committer = SQLiteCanonicalCommitter()

    let reconciliation = try committer.prepare(request)
    let first = try committer.commit(request)
    let retry = try committer.commit(request)

    #expect(reconciliation.blockingCount == 0)
    #expect(first.status == .committed)
    #expect(retry.status == .unchanged)
    #expect(first.canonicalChecksum == retry.canonicalChecksum)
    let event = try #require(request.events.first)
    #expect(request.events.count == 1)
    #expect(
      event.eventID
        == (try StableCanonicalID.event(
          sourceRecordID: event.sourceRecordID, effectOrdinal: 0)))
    #expect(
      event.accountID
        == (try StableCanonicalID.account(
          profileID: staged.manifest.profileID, sourceAccountID: "synthetic-asset")))
    #expect(event.occurredAt.timeZone == zone)
    #expect(event.occurredAt.instant.epochMilliseconds == 1_738_527_400_000)
    let currencyBinding = try #require(event.sourceBindings.first { $0.semantic == .currency })
    #expect(currencyBinding.provenance.locator.table == "CURRENCY")
    #expect(currencyBinding.provenance.locator.columnName == "ISO")
    try FileManager.default.removeItem(at: staged.url)
    let sidecars = try committer.sidecars(at: canonical, eventID: event.eventID)
    #expect(sidecars.count == 9)
    #expect(sidecars.allSatisfy { $0.provenance.locator.table == "INOUTCOME" })
    let preservation = try committer.receiptOwnedPreservation(
      at: canonical, receiptID: staged.manifest.stagingID)
    #expect(preservation.anchors.count == 6)
    #expect(preservation.payloads.count == 4)
    #expect(
      Set(preservation.anchors.map(\.sourceTable)) == ["ASSETS", "ZCATEGORY", "CURRENCY"])
    #expect(
      Set(preservation.payloads.map { $0.provenance.locator.table })
        == ["ASSETS", "ZCATEGORY", "CURRENCY"])
    #expect(
      preservation.payloads.allSatisfy {
        $0.anchorID != event.eventID && $0.provenance.locator.recordKey != "transaction-record"
      })
    #expect(
      Set(
        preservation.payloads.filter { $0.provenance.locator.table == "CURRENCY" }
          .compactMap { $0.provenance.locator.columnName }) == ["uid", "ISO"])
  }

  @Test("authenticated preservation-only stage commits empty-table anchors without events")
  func commitsPreservationOnlyStage() throws {
    let staged = try makeAuthenticatedStage(preservationOnly: true)
    let canonical = FileManager.default.temporaryDirectory.appendingPathComponent(
      "v19-preservation-only-\(UUID().uuidString).sqlite")
    defer {
      try? FileManager.default.removeItem(at: staged.url)
      try? FileManager.default.removeItem(at: canonical)
    }
    let request = try MoneyManagerV19Adapter.canonicalCommitRequest(
      canonicalDatabaseURL: canonical, stagingDatabaseURL: staged.url,
      expectedManifest: staged.manifest, expectedContentDigest: staged.digest,
      sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0))
    let committer = SQLiteCanonicalCommitter()

    #expect(request.events.isEmpty)
    #expect(try committer.prepare(request).blockingCount == 0)
    let first = try committer.commit(request)
    let retry = try committer.commit(request)
    #expect(first.status == .committed)
    #expect(retry.status == .unchanged)
    #expect(first.canonicalChecksum == retry.canonicalChecksum)
    #expect(try committer.eventCount(at: canonical) == 0)
    try FileManager.default.removeItem(at: staged.url)
    let preservation = try committer.receiptOwnedPreservation(
      at: canonical, receiptID: staged.manifest.stagingID)
    #expect(preservation.anchors.count == 4)
    #expect(preservation.anchors.allSatisfy { $0.subjectKind == .table })
    #expect(preservation.anchors.allSatisfy { $0.sourceRecordKey == nil })
    #expect(preservation.payloads.isEmpty)
  }

  @Test("failure after a receipt-owned insert rolls back the new destination")
  func receiptOwnedFailureRollsBack() throws {
    let staged = try makeAuthenticatedStage()
    let canonical = FileManager.default.temporaryDirectory.appendingPathComponent(
      "v19-preservation-failure-\(UUID().uuidString).sqlite")
    defer {
      try? FileManager.default.removeItem(at: staged.url)
      try? FileManager.default.removeItem(at: canonical)
    }
    let request = try MoneyManagerV19Adapter.canonicalCommitRequest(
      canonicalDatabaseURL: canonical, stagingDatabaseURL: staged.url,
      expectedManifest: staged.manifest, expectedContentDigest: staged.digest,
      sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0))

    #expect(throws: CanonicalCommitError.injectedFailure) {
      try SQLiteCanonicalCommitter(testingFailAfterPreservationInserts: 1).commit(request)
    }
    #expect(!FileManager.default.fileExists(atPath: canonical.path))
  }

  @Test("failure after preservation insertion leaves populated checksum and row counts stable")
  func populatedLedgerPreservationFailureRollsBack() throws {
    let baselineStage = try makeAuthenticatedStage()
    let secondStage = try makeAuthenticatedStage(
      artifactIdentifier: 2, transactionUID: "synthetic-transaction-two")
    let canonical = FileManager.default.temporaryDirectory.appendingPathComponent(
      "v19-populated-preservation-failure-\(UUID().uuidString).sqlite")
    defer {
      try? FileManager.default.removeItem(at: baselineStage.url)
      try? FileManager.default.removeItem(at: secondStage.url)
      try? FileManager.default.removeItem(at: canonical)
    }
    let baselineRequest = try MoneyManagerV19Adapter.canonicalCommitRequest(
      canonicalDatabaseURL: canonical, stagingDatabaseURL: baselineStage.url,
      expectedManifest: baselineStage.manifest, expectedContentDigest: baselineStage.digest,
      sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0))
    let secondRequest = try MoneyManagerV19Adapter.canonicalCommitRequest(
      canonicalDatabaseURL: canonical, stagingDatabaseURL: secondStage.url,
      expectedManifest: secondStage.manifest, expectedContentDigest: secondStage.digest,
      sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0))
    let committer = SQLiteCanonicalCommitter()
    _ = try committer.commit(baselineRequest)
    let checksumBefore = try committer.canonicalChecksum(at: canonical)
    let countsBefore = try canonicalTableCounts(canonical)

    #expect(throws: CanonicalCommitError.injectedFailure) {
      try SQLiteCanonicalCommitter(testingFailAfterPreservationInserts: 1)
        .commit(secondRequest)
    }
    #expect(try committer.canonicalChecksum(at: canonical) == checksumBefore)
    #expect(try canonicalTableCounts(canonical) == countsBefore)
  }

  @Test("forged missing or orphaned receipt-owned rows make retries conflict")
  func receiptOwnedIntegrityConflicts() throws {
    let mutations = [
      "UPDATE receipt_preservation_payload SET payload=CAST('synthetic-forgery' AS BLOB) WHERE payload_id=(SELECT payload_id FROM receipt_preservation_payload LIMIT 1)",
      "PRAGMA ignore_check_constraints=ON; UPDATE receipt_preservation_payload SET provenance_id=(SELECT provenance_id FROM event_source_binding LIMIT 1) WHERE payload_id=(SELECT payload_id FROM receipt_preservation_payload LIMIT 1)",
      "PRAGMA ignore_check_constraints=ON; UPDATE receipt_preservation_membership SET subject_kind='table' WHERE source_subject_id=(SELECT source_subject_id FROM receipt_preservation_membership WHERE subject_kind='record' LIMIT 1)",
      "DELETE FROM receipt_preservation_membership WHERE subject_kind='field' AND source_subject_id=(SELECT source_subject_id FROM receipt_preservation_payload LIMIT 1)",
      "INSERT INTO receipt_preservation_anchor SELECT '\(id(62))', idempotency_key, '\(id(63))', 'table', artifact_sha256, profile_id, adapter_version, NULL, 'SYNTHETIC_ORPHAN', NULL FROM receipt_preservation_anchor LIMIT 1",
    ]
    for (index, mutation) in mutations.enumerated() {
      let staged = try makeAuthenticatedStage()
      let canonical = FileManager.default.temporaryDirectory.appendingPathComponent(
        "v19-preservation-integrity-\(index)-\(UUID().uuidString).sqlite")
      defer {
        try? FileManager.default.removeItem(at: staged.url)
        try? FileManager.default.removeItem(at: canonical)
      }
      let request = try MoneyManagerV19Adapter.canonicalCommitRequest(
        canonicalDatabaseURL: canonical, stagingDatabaseURL: staged.url,
        expectedManifest: staged.manifest, expectedContentDigest: staged.digest,
        sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0))
      let unrelatedStage = try makeAuthenticatedStage(
        artifactIdentifier: index + 10,
        transactionUID: "synthetic-unrelated-\(index)")
      defer { try? FileManager.default.removeItem(at: unrelatedStage.url) }
      let unrelatedRequest = try MoneyManagerV19Adapter.canonicalCommitRequest(
        canonicalDatabaseURL: canonical, stagingDatabaseURL: unrelatedStage.url,
        expectedManifest: unrelatedStage.manifest, expectedContentDigest: unrelatedStage.digest,
        sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0))
      let committer = SQLiteCanonicalCommitter()
      _ = try committer.commit(request)
      try withAdapterDatabase(canonical) { database in
        guard sqlite3_exec(database, mutation, nil, nil, nil) == SQLITE_OK else {
          throw AdapterTestFailure.sqlite
        }
      }
      let countsBefore = try canonicalTableCounts(canonical)
      #expect(throws: CanonicalCommitError.idempotencyConflict) {
        try committer.commit(request)
      }
      #expect(throws: CanonicalCommitError.self) {
        try committer.commit(unrelatedRequest)
      }
      #expect(try canonicalTableCounts(canonical) == countsBefore)
    }
  }

  @Test("unrelated import rejects rehashed cross-receipt preservation membership")
  func unrelatedImportRejectsRehashedCrossReceiptPreservationMembership() throws {
    let firstStage = try makeAuthenticatedStage(preservationOnly: true, artifactIdentifier: 21)
    let secondStage = try makeAuthenticatedStage(preservationOnly: true, artifactIdentifier: 22)
    let unrelatedStage = try makeAuthenticatedStage(preservationOnly: true, artifactIdentifier: 23)
    let canonical = FileManager.default.temporaryDirectory.appendingPathComponent(
      "v19-cross-receipt-preservation-\(UUID().uuidString).sqlite")
    defer {
      try? FileManager.default.removeItem(at: firstStage.url)
      try? FileManager.default.removeItem(at: secondStage.url)
      try? FileManager.default.removeItem(at: unrelatedStage.url)
      try? FileManager.default.removeItem(at: canonical)
    }
    let zone = try SourceTimeZone(fixedOffsetSeconds: 0)
    let firstRequest = try MoneyManagerV19Adapter.canonicalCommitRequest(
      canonicalDatabaseURL: canonical, stagingDatabaseURL: firstStage.url,
      expectedManifest: firstStage.manifest, expectedContentDigest: firstStage.digest,
      sourceTimeZone: zone)
    let secondRequest = try MoneyManagerV19Adapter.canonicalCommitRequest(
      canonicalDatabaseURL: canonical, stagingDatabaseURL: secondStage.url,
      expectedManifest: secondStage.manifest, expectedContentDigest: secondStage.digest,
      sourceTimeZone: zone)
    let unrelatedRequest = try MoneyManagerV19Adapter.canonicalCommitRequest(
      canonicalDatabaseURL: canonical, stagingDatabaseURL: unrelatedStage.url,
      expectedManifest: unrelatedStage.manifest, expectedContentDigest: unrelatedStage.digest,
      sourceTimeZone: zone)
    let committer = SQLiteCanonicalCommitter()
    _ = try committer.commit(firstRequest)
    _ = try committer.commit(secondRequest)

    try withAdapterDatabase(canonical) { database in
      try executeAdapterTestSQL(
        database,
        "UPDATE receipt_preservation_membership SET idempotency_key='\(secondStage.manifest.stagingID)' WHERE idempotency_key='\(firstStage.manifest.stagingID)' AND source_subject_id=(SELECT source_subject_id FROM receipt_preservation_membership WHERE idempotency_key='\(firstStage.manifest.stagingID)' ORDER BY source_subject_id LIMIT 1)"
      )
      try rehashSyntheticReceipt(
        database, receiptID: firstStage.manifest.stagingID)
      try rehashSyntheticReceipt(
        database, receiptID: secondStage.manifest.stagingID)
    }
    let checksumBefore = try adapterTestCanonicalChecksum(canonical)
    let countsBefore = try canonicalTableCounts(canonical)

    #expect(throws: CanonicalCommitError.self) {
      try committer.commit(unrelatedRequest)
    }
    #expect(try adapterTestCanonicalChecksum(canonical) == checksumBefore)
    #expect(try canonicalTableCounts(canonical) == countsBefore)
  }

  @Test("unrelated import rejects rehashed cross-receipt preservation payload swap")
  func unrelatedImportRejectsRehashedCrossReceiptPreservationPayloadSwap() throws {
    let firstStage = try makeAuthenticatedStage(
      includeUnknownTable: true, preservationOnly: true, artifactIdentifier: 24,
      unknownPayload: Data([0x10, 0x11, 0x12]))
    let secondStage = try makeAuthenticatedStage(
      includeUnknownTable: true, preservationOnly: true, artifactIdentifier: 25,
      unknownPayload: Data([0x20, 0x21, 0x22]))
    let unrelatedStage = try makeAuthenticatedStage(
      preservationOnly: true, artifactIdentifier: 26)
    let canonical = FileManager.default.temporaryDirectory.appendingPathComponent(
      "v19-cross-receipt-payload-\(UUID().uuidString).sqlite")
    defer {
      try? FileManager.default.removeItem(at: firstStage.url)
      try? FileManager.default.removeItem(at: secondStage.url)
      try? FileManager.default.removeItem(at: unrelatedStage.url)
      try? FileManager.default.removeItem(at: canonical)
    }
    let zone = try SourceTimeZone(fixedOffsetSeconds: 0)
    let firstRequest = try MoneyManagerV19Adapter.canonicalCommitRequest(
      canonicalDatabaseURL: canonical, stagingDatabaseURL: firstStage.url,
      expectedManifest: firstStage.manifest, expectedContentDigest: firstStage.digest,
      sourceTimeZone: zone)
    let secondRequest = try MoneyManagerV19Adapter.canonicalCommitRequest(
      canonicalDatabaseURL: canonical, stagingDatabaseURL: secondStage.url,
      expectedManifest: secondStage.manifest, expectedContentDigest: secondStage.digest,
      sourceTimeZone: zone)
    let unrelatedRequest = try MoneyManagerV19Adapter.canonicalCommitRequest(
      canonicalDatabaseURL: canonical, stagingDatabaseURL: unrelatedStage.url,
      expectedManifest: unrelatedStage.manifest, expectedContentDigest: unrelatedStage.digest,
      sourceTimeZone: zone)
    let committer = SQLiteCanonicalCommitter()
    _ = try committer.commit(firstRequest)
    _ = try committer.commit(secondRequest)

    try withAdapterDatabase(canonical) { database in
      let firstPayloadID = try #require(
        adapterTestTextRows(
          database,
          sql: "SELECT payload_id FROM receipt_preservation_payload WHERE idempotency_key='\(firstStage.manifest.stagingID)'"
        ).first?.first ?? nil)
      let secondPayloadID = try #require(
        adapterTestTextRows(
          database,
          sql: "SELECT payload_id FROM receipt_preservation_payload WHERE idempotency_key='\(secondStage.manifest.stagingID)'"
        ).first?.first ?? nil)
      try executeAdapterTestSQL(
        database,
        "UPDATE receipt_preservation_payload SET payload=CASE payload_id WHEN '\(firstPayloadID)' THEN X'202122' WHEN '\(secondPayloadID)' THEN X'101112' END WHERE payload_id IN ('\(firstPayloadID)','\(secondPayloadID)')"
      )
      try rehashSyntheticReceipt(database, receiptID: firstStage.manifest.stagingID)
      try rehashSyntheticReceipt(database, receiptID: secondStage.manifest.stagingID)
    }
    let checksumBefore = try adapterTestCanonicalChecksum(canonical)
    let countsBefore = try canonicalTableCounts(canonical)

    #expect(throws: CanonicalCommitError.self) {
      try committer.commit(unrelatedRequest)
    }
    #expect(try adapterTestCanonicalChecksum(canonical) == checksumBefore)
    #expect(try canonicalTableCounts(canonical) == countsBefore)
  }

  @Test("unrelated import rejects a rehashed NULL-to-NUL preservation metadata mutation")
  func unrelatedImportRejectsRehashedOptionalEncodingCollision() throws {
    let staged = try makeAuthenticatedStage(
      includeUnknownTable: true, preservationOnly: true, artifactIdentifier: 27,
      unknownDeclaredType: nil)
    let unrelatedStage = try makeAuthenticatedStage(
      preservationOnly: true, artifactIdentifier: 28)
    let canonical = FileManager.default.temporaryDirectory.appendingPathComponent(
      "v19-optional-collision-\(UUID().uuidString).sqlite")
    defer {
      try? FileManager.default.removeItem(at: staged.url)
      try? FileManager.default.removeItem(at: unrelatedStage.url)
      try? FileManager.default.removeItem(at: canonical)
    }
    let zone = try SourceTimeZone(fixedOffsetSeconds: 0)
    let request = try MoneyManagerV19Adapter.canonicalCommitRequest(
      canonicalDatabaseURL: canonical, stagingDatabaseURL: staged.url,
      expectedManifest: staged.manifest, expectedContentDigest: staged.digest,
      sourceTimeZone: zone)
    let unrelatedRequest = try MoneyManagerV19Adapter.canonicalCommitRequest(
      canonicalDatabaseURL: canonical, stagingDatabaseURL: unrelatedStage.url,
      expectedManifest: unrelatedStage.manifest, expectedContentDigest: unrelatedStage.digest,
      sourceTimeZone: zone)
    let committer = SQLiteCanonicalCommitter()
    _ = try committer.commit(request)
    try withAdapterDatabase(canonical) { database in
      try executeAdapterTestSQL(
        database,
        "PRAGMA ignore_check_constraints=ON; UPDATE receipt_preservation_payload SET declared_type=char(0) WHERE idempotency_key='\(staged.manifest.stagingID)'")
      try rehashSyntheticReceipt(database, receiptID: staged.manifest.stagingID)
    }
    let checksumBefore = try adapterTestCanonicalChecksum(canonical)
    let countsBefore = try canonicalTableCounts(canonical)

    #expect(throws: CanonicalCommitError.self) {
      try committer.commit(unrelatedRequest)
    }
    #expect(try adapterTestCanonicalChecksum(canonical) == checksumBefore)
    #expect(try canonicalTableCounts(canonical) == countsBefore)
  }

  @Test("oversized persisted payloads fail before canonical state can advance")
  func oversizedPersistedPayloadsFailBoundedly() throws {
    for (index, table) in ["sidecar_reference", "receipt_preservation_payload"].enumerated() {
      let staged = try makeAuthenticatedStage(artifactIdentifier: 30 + index)
      let unrelatedStage = try makeAuthenticatedStage(
        artifactIdentifier: 40 + index, transactionUID: "synthetic-oversize-unrelated-\(index)")
      let canonical = FileManager.default.temporaryDirectory.appendingPathComponent(
        "v19-oversized-payload-\(index)-\(UUID().uuidString).sqlite")
      defer {
        try? FileManager.default.removeItem(at: staged.url)
        try? FileManager.default.removeItem(at: unrelatedStage.url)
        try? FileManager.default.removeItem(at: canonical)
      }
      let request = try MoneyManagerV19Adapter.canonicalCommitRequest(
        canonicalDatabaseURL: canonical, stagingDatabaseURL: staged.url,
        expectedManifest: staged.manifest, expectedContentDigest: staged.digest,
        sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0))
      let unrelatedRequest = try MoneyManagerV19Adapter.canonicalCommitRequest(
        canonicalDatabaseURL: canonical, stagingDatabaseURL: unrelatedStage.url,
        expectedManifest: unrelatedStage.manifest, expectedContentDigest: unrelatedStage.digest,
        sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0))
      let committer = SQLiteCanonicalCommitter()
      _ = try committer.commit(request)
      try withAdapterDatabase(canonical) { database in
        // SQLite's zero-blob stores the requested logical size without constructing a Swift Data.
        try executeAdapterTestSQL(
          database,
          "UPDATE \(table) SET payload=zeroblob(\(CanonicalCommitDigest.maximumSidecarBytes + 1)) WHERE rowid=(SELECT rowid FROM \(table) LIMIT 1)"
        )
      }
      let countsBefore = try canonicalTableCounts(canonical)

      #expect(throws: CanonicalCommitError.idempotencyConflict) {
        try committer.commit(unrelatedRequest)
      }
      #expect(try canonicalTableCounts(canonical) == countsBefore)
    }
  }

  @Test("v19 adapter rejects an oversized staged zero-blob before digest materialization")
  func v19AdapterRejectsOversizedStagedPayloadBoundedly() throws {
    let staged = try makeAuthenticatedStage()
    let canonical = FileManager.default.temporaryDirectory.appendingPathComponent(
      "v19-oversized-stage-\(UUID().uuidString).sqlite")
    defer {
      try? FileManager.default.removeItem(at: staged.url)
      try? FileManager.default.removeItem(at: canonical)
    }
    try withAdapterDatabase(staged.url) { database in
      try executeAdapterTestSQL(
        database,
        "UPDATE staged_field SET payload=zeroblob(\(CanonicalCommitDigest.maximumSidecarBytes + 1)) WHERE rowid=(SELECT rowid FROM staged_field LIMIT 1)"
      )
    }

    #expect(throws: MoneyManagerV19AdapterError.invalidStagingInventory) {
      try MoneyManagerV19Adapter.prepare(
        stagingDatabaseURL: staged.url, expectedManifest: staged.manifest,
        expectedContentDigest: staged.digest)
    }
    #expect(throws: MoneyManagerV19AdapterError.invalidStagingInventory) {
      try MoneyManagerV19Adapter.canonicalCommitRequest(
        canonicalDatabaseURL: canonical, stagingDatabaseURL: staged.url,
        expectedManifest: staged.manifest, expectedContentDigest: staged.digest,
        sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0))
    }
    #expect(!FileManager.default.fileExists(atPath: canonical.path))
  }

  @Test("v19 adapter rejects same-inode mutation across every staged materialization seam")
  func v19AdapterRejectsSameInodeMutationAcrossReads() throws {
    for point in [
      MoneyManagerV19AdapterReadPoint.afterAuthentication,
      MoneyManagerV19AdapterReadPoint.duringStagedRecords,
    ] {
      for requestPath in [false, true] {
        let staged = try makeAuthenticatedStage()
        let canonical = FileManager.default.temporaryDirectory.appendingPathComponent(
          "v19-same-inode-stage-\(UUID().uuidString).sqlite")
        defer {
          try? FileManager.default.removeItem(at: staged.url)
          try? FileManager.default.removeItem(at: canonical)
        }
        let mutation: (MoneyManagerV19AdapterReadPoint) throws -> Void = { observed in
          guard observed == point else { return }
          try mutateAdapterStageSameInode(staged.url)
        }
        if requestPath {
          #expect(throws: MoneyManagerV19AdapterError.invalidStagingInventory) {
            try MoneyManagerV19Adapter.canonicalCommitRequest(
              canonicalDatabaseURL: canonical, stagingDatabaseURL: staged.url,
              expectedManifest: staged.manifest, expectedContentDigest: staged.digest,
              sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0),
              testingMutation: mutation)
          }
        } else {
          #expect(throws: MoneyManagerV19AdapterError.invalidStagingInventory) {
            try MoneyManagerV19Adapter.prepare(
              stagingDatabaseURL: staged.url, expectedManifest: staged.manifest,
              expectedContentDigest: staged.digest, testingMutation: mutation)
          }
        }
        #expect(!FileManager.default.fileExists(atPath: canonical.path))
      }
    }
  }

  @Test("post-preflight oversized mutation cannot bypass v19 materialization bounds")
  func v19AdapterRejectsPostPreflightOversizedMutation() throws {
    for requestPath in [false, true] {
      let staged = try makeAuthenticatedStage()
      let canonical = FileManager.default.temporaryDirectory.appendingPathComponent(
        "v19-post-preflight-oversized-\(UUID().uuidString).sqlite")
      defer {
        try? FileManager.default.removeItem(at: staged.url)
        try? FileManager.default.removeItem(at: canonical)
      }
      let mutation: (MoneyManagerV19AdapterReadPoint) throws -> Void = { point in
        guard point == .duringStagedRecords else { return }
        try withAdapterDatabase(staged.url) { database in
          try executeAdapterTestSQL(
            database,
            "UPDATE staged_field SET payload=zeroblob(\(CanonicalCommitDigest.maximumSidecarBytes + 1)) WHERE column_name='NOTE'")
        }
      }
      if requestPath {
        #expect(throws: MoneyManagerV19AdapterError.invalidStagingInventory) {
          try MoneyManagerV19Adapter.canonicalCommitRequest(
            canonicalDatabaseURL: canonical, stagingDatabaseURL: staged.url,
            expectedManifest: staged.manifest, expectedContentDigest: staged.digest,
            sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0),
            testingMutation: mutation)
        }
      } else {
        #expect(throws: MoneyManagerV19AdapterError.invalidStagingInventory) {
          try MoneyManagerV19Adapter.prepare(
            stagingDatabaseURL: staged.url, expectedManifest: staged.manifest,
            expectedContentDigest: staged.digest, testingMutation: mutation)
        }
      }
      #expect(!FileManager.default.fileExists(atPath: canonical.path))
    }
  }

  @Test("authenticated staged unknown and transfer types are preserved without blocking import")
  func preservesUnprovenStagedTypes() throws {
    for type in ["3", "4", "7"] {
      let staged = try makeAuthenticatedStage(transactionType: type)
      let canonical = FileManager.default.temporaryDirectory.appendingPathComponent(
        "preserved-v19-\(type)-\(UUID().uuidString).sqlite")
      defer {
        try? FileManager.default.removeItem(at: staged.url)
        try? FileManager.default.removeItem(at: canonical)
      }
      let plan = try MoneyManagerV19Adapter.prepare(
        stagingDatabaseURL: staged.url, expectedManifest: staged.manifest,
        expectedContentDigest: staged.digest)
      #expect(plan.mappedEvents.isEmpty)
      #expect(!plan.isBlocked)
      #expect(plan.blocksLosslessCertification)
      #expect(plan.blockedRecords.isEmpty)
      if type == "7" {
        #expect(plan.preservedReasons.values.contains(.unknownTransactionType))
      } else {
        #expect(plan.preservedReasons.values.contains(.transferDirectionUnproven))
      }
      let request = try MoneyManagerV19Adapter.canonicalCommitRequest(
        canonicalDatabaseURL: canonical, stagingDatabaseURL: staged.url,
        expectedManifest: staged.manifest, expectedContentDigest: staged.digest,
        sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0))
      #expect(request.events.isEmpty)
      #expect(try SQLiteCanonicalCommitter().prepare(request).blockingCount == 0)
      #expect(try SQLiteCanonicalCommitter().commit(request).status == .committed)
    }
  }

  @Test("unresolved category is sidecar-preserved so import is not blocked")
  func preservesUnresolvedCategory() throws {
    let staged = try makeAuthenticatedStage(transactionCategoryUID: "missing-category")
    let canonical = FileManager.default.temporaryDirectory.appendingPathComponent(
      "preserved-category-\(UUID().uuidString).sqlite")
    defer {
      try? FileManager.default.removeItem(at: staged.url)
      try? FileManager.default.removeItem(at: canonical)
    }
    let plan = try MoneyManagerV19Adapter.prepare(
      stagingDatabaseURL: staged.url, expectedManifest: staged.manifest,
      expectedContentDigest: staged.digest)

    #expect(plan.mappedEvents.isEmpty)
    #expect(plan.blockedRecords.isEmpty)
    #expect(!plan.isBlocked)
    #expect(plan.preservedReasons.values.contains(.unresolvedCategory))
    let request = try MoneyManagerV19Adapter.canonicalCommitRequest(
      canonicalDatabaseURL: canonical, stagingDatabaseURL: staged.url,
      expectedManifest: staged.manifest, expectedContentDigest: staged.digest,
      sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0))
    #expect(request.events.isEmpty)
    #expect(try SQLiteCanonicalCommitter().commit(request).status == .committed)
  }

  @Test("unknown tables records and blob fields commit as receipt-owned preservation")
  func preservesUnknownStagedRecords() throws {
    let staged = try makeAuthenticatedStage(includeUnknownTable: true)
    let canonical = FileManager.default.temporaryDirectory.appendingPathComponent(
      "unknown-v19-\(UUID().uuidString).sqlite")
    defer {
      try? FileManager.default.removeItem(at: staged.url)
      try? FileManager.default.removeItem(at: canonical)
    }

    let plan = try MoneyManagerV19Adapter.prepare(
      stagingDatabaseURL: staged.url, expectedManifest: staged.manifest,
      expectedContentDigest: staged.digest)

    #expect(plan.opaqueRecords.count == 1)
    #expect(plan.opaqueRecords[0].tableName == "UNOBSERVED")
    #expect(plan.opaqueRecords[0].fields[0].storageClass == .blob)
    #expect(plan.opaqueRecords[0].fields[0].payload == Data([0, 0xff, 1]))
    #expect(!plan.isBlocked)
    let request = try MoneyManagerV19Adapter.canonicalCommitRequest(
      canonicalDatabaseURL: canonical, stagingDatabaseURL: staged.url,
      expectedManifest: staged.manifest, expectedContentDigest: staged.digest,
      sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0))
    let committer = SQLiteCanonicalCommitter()
    #expect(try committer.prepare(request).blockingCount == 0)
    let first = try committer.commit(request)
    let retry = try committer.commit(request)
    #expect(first.canonicalChecksum == retry.canonicalChecksum)
    try FileManager.default.removeItem(at: staged.url)
    let preservation = try committer.receiptOwnedPreservation(
      at: canonical, receiptID: staged.manifest.stagingID)
    let unknownAnchors = preservation.anchors.filter { $0.sourceTable == "UNOBSERVED" }
    let emptyAnchor = preservation.anchors.first { $0.sourceTable == "EMPTY_UNOBSERVED" }
    let unknownPayload = preservation.payloads.first {
      $0.provenance.locator.table == "UNOBSERVED"
    }
    let event = try #require(request.events.first)
    let eventSidecars = try committer.sidecars(at: canonical, eventID: event.eventID)
    #expect(eventSidecars.allSatisfy { $0.provenance.locator.table == "INOUTCOME" })
    #expect(unknownAnchors.count == 2)
    #expect(emptyAnchor?.subjectKind == .table)
    #expect(emptyAnchor?.sourceRecordKey == nil)
    #expect(unknownPayload?.storageClass == .blob)
    #expect(unknownPayload?.payload == Data([0, 0xff, 1]))
    #expect(unknownPayload?.provenance.artifactSHA256 == staged.manifest.artifactSHA256)
    #expect(unknownPayload?.provenance.profileID == staged.manifest.profileID)
    #expect(unknownPayload?.provenance.adapterVersion == staged.manifest.adapterVersion)
    #expect(unknownPayload?.provenance.locator.recordKey == "opaque-record")
    #expect(unknownPayload?.provenance.locator.columnOrdinal == 0)
    #expect(unknownPayload?.provenance.locator.columnName == "opaque")
    #expect(
      !event.sidecarReferences.contains {
        $0.sidecarID == unknownPayload?.sourceSubjectID
      })
  }

  @Test("profile-family aliases cannot enter the observed profile namespace")
  func rejectsProfileAlias() throws {
    let staged = try makeAuthenticatedStage()
    defer { try? FileManager.default.removeItem(at: staged.url) }
    let alias = StagingManifest(
      stagingID: staged.manifest.stagingID, artifactSHA256: staged.manifest.artifactSHA256,
      profileID: "\(MoneyManagerV19Adapter.observedProfileID)-alias",
      adapterVersion: staged.manifest.adapterVersion, tableCount: staged.manifest.tableCount,
      recordCount: staged.manifest.recordCount, fieldCount: staged.manifest.fieldCount,
      opaqueByteCount: staged.manifest.opaqueByteCount)

    #expect(throws: MoneyManagerV19AdapterError.unsupportedProfile) {
      _ = try MoneyManagerV19Adapter.prepare(
        stagingDatabaseURL: staged.url, expectedManifest: alias,
        expectedContentDigest: staged.digest)
    }
  }

  @Test("duplicate currency UIDs fail closed instead of trapping")
  func rejectsDuplicateCurrencyUIDs() throws {
    let staged = try makeAuthenticatedStage(includeDuplicateCurrency: true)
    defer { try? FileManager.default.removeItem(at: staged.url) }

    #expect(throws: MoneyManagerV19AdapterError.invalidSourceRecord) {
      _ = try MoneyManagerV19Adapter.prepare(
        stagingDatabaseURL: staged.url, expectedManifest: staged.manifest,
        expectedContentDigest: staged.digest)
    }
  }

  @Test("duplicate transaction UIDs fail closed before canonical commit")
  func rejectsDuplicateTransactionUIDs() throws {
    let staged = try makeAuthenticatedStage(includeDuplicateTransactionUID: true)
    defer { try? FileManager.default.removeItem(at: staged.url) }
    let request = try MoneyManagerV19Adapter.canonicalCommitRequest(
      canonicalDatabaseURL: FileManager.default.temporaryDirectory.appendingPathComponent(
        "duplicate-uid-(UUID().uuidString).sqlite"),
      stagingDatabaseURL: staged.url, expectedManifest: staged.manifest,
      expectedContentDigest: staged.digest,
      sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 19_800))

    #expect(throws: CanonicalCommitError.unsafeMapping) {
      try SQLiteCanonicalCommitter().commit(request)
    }
  }
}

private func makeAuthenticatedStage(
  transactionType: String = "0", includeUnknownTable: Bool = false,
  includeDuplicateCurrency: Bool = false,
  includeDuplicateTransactionUID: Bool = false,
  transactionCategoryUID: String = "synthetic-category",
  preservationOnly: Bool = false,
  artifactIdentifier: Int = 1,
  transactionUID: String = "synthetic-transaction",
  unknownPayload: Data = Data([0, 0xff, 1]),
  unknownDeclaredType: String? = "BLOB"
) throws -> (url: URL, manifest: StagingManifest, digest: String) {
  let artifact = id(artifactIdentifier)
  let stageID = StableStagingID.stage(
    artifactSHA256: artifact, profileID: MoneyManagerV19Adapter.observedProfileID,
    adapterVersion: MoneyManagerV19Adapter.version)
  func record(_ table: String, _ key: String, _ values: [(String, String)]) throws -> StagedRecord {
    let fields = try values.enumerated().map { ordinal, pair -> StagedField in
      let locator = SourceLocator(
        table: table, recordKey: key, columnOrdinal: ordinal, columnName: pair.0)
      let fieldID = StableStagingID.field(stagingID: stageID, locator: locator)
      let provenance = FieldProvenance(
        artifactSHA256: artifact,
        profileID: MoneyManagerV19Adapter.observedProfileID,
        adapterVersion: MoneyManagerV19Adapter.version, locator: locator, deterministicID: fieldID)
      return StagedField(
        id: fieldID, ordinal: ordinal, name: pair.0,
        sidecar: try OpaqueSidecar(
          declaredType: "TEXT", storageClass: .text,
          payload: Data(pair.1.utf8), provenance: provenance))
    }
    return StagedRecord(
      id: StableStagingID.record(stagingID: stageID, table: table, recordKey: key),
      recordKey: key, fields: fields,
      opaqueByteCount: fields.reduce(0) { $0 + $1.sidecar.payload.count })
  }
  let asset = try record("ASSETS", "asset-record", [("uid", "synthetic-asset")])
  let category = try record("ZCATEGORY", "category-record", [("uid", "synthetic-category")])
  let currency = try record(
    "CURRENCY", "currency-record", [("uid", "synthetic-currency"), ("ISO", "USD")])
  let duplicateCurrency =
    includeDuplicateCurrency
    ? try record("CURRENCY", "currency-duplicate", [("uid", "synthetic-currency"), ("ISO", "EUR")])
    : nil
  let transaction = try record(
    "INOUTCOME", "transaction-record",
    [
      ("uid", transactionUID), ("assetUid", "synthetic-asset"),
      ("currencyUid", "synthetic-currency"), ("DO_TYPE", transactionType),
      ("ctgUid", transactionCategoryUID), ("ZMONEY", "12.30"), ("WDATE", "2025-02-03"),
      ("ZDATE", "1738547200000"), ("NOTE", "synthetic"),
    ])
  let duplicateTransaction = includeDuplicateTransactionUID
    ? try record(
      "INOUTCOME", "transaction-duplicate",
      [
        ("uid", "synthetic-transaction"), ("assetUid", "synthetic-asset"),
        ("currencyUid", "synthetic-currency"), ("DO_TYPE", transactionType),
        ("ctgUid", transactionCategoryUID), ("ZMONEY", "12.30"),
        ("WDATE", "2025-02-03"), ("ZDATE", "1738547200000"), ("NOTE", "duplicate"),
      ])
    : nil
  var unknown: StagedRecord?
  if includeUnknownTable {
    let locator = SourceLocator(
      table: "UNOBSERVED", recordKey: "opaque-record", columnOrdinal: 0, columnName: "opaque")
    let fieldID = StableStagingID.field(stagingID: stageID, locator: locator)
    let provenance = FieldProvenance(
      artifactSHA256: artifact,
      profileID: MoneyManagerV19Adapter.observedProfileID,
      adapterVersion: MoneyManagerV19Adapter.version,
      locator: locator, deterministicID: fieldID)
    let field = StagedField(
      id: fieldID, ordinal: 0, name: "opaque",
      sidecar: try OpaqueSidecar(
        declaredType: unknownDeclaredType, storageClass: .blob, payload: unknownPayload,
        provenance: provenance))
    unknown = StagedRecord(
      id: StableStagingID.record(
        stagingID: stageID, table: "UNOBSERVED", recordKey: "opaque-record"),
      recordKey: "opaque-record", fields: [field], opaqueByteCount: field.sidecar.payload.count)
  }
  let sourceTables =
    (preservationOnly
      ? [("ASSETS", []), ("ZCATEGORY", []), ("CURRENCY", []), ("INOUTCOME", [])]
      : [
        ("ASSETS", [asset]), ("ZCATEGORY", [category]),
        ("CURRENCY", [currency] + (duplicateCurrency.map { [$0] } ?? [])),
        ("INOUTCOME", [transaction] + (duplicateTransaction.map { [$0] } ?? [])),
      ])
    + (unknown.map { [("UNOBSERVED", [$0]), ("EMPTY_UNOBSERVED", [])] } ?? [])
  let tables = sourceTables.map { name, records in
    StagedTable(
      id: StableStagingID.table(stagingID: stageID, table: name), name: name, records: records)
  }
  let records =
    (preservationOnly
      ? []
      : [asset, category, currency] + (duplicateCurrency.map { [$0] } ?? []) + [transaction]
        + (duplicateTransaction.map { [$0] } ?? []))
      + (unknown.map { [$0] } ?? [])
  let manifest = StagingManifest(
    stagingID: stageID, artifactSHA256: artifact,
    profileID: MoneyManagerV19Adapter.observedProfileID,
    adapterVersion: MoneyManagerV19Adapter.version,
    tableCount: tables.count, recordCount: records.count,
    fieldCount: records.reduce(0) { $0 + $1.fields.count },
    opaqueByteCount: records.reduce(0) { $0 + $1.opaqueByteCount })
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "v19-stage-\(UUID().uuidString).sqlite")
  let digest = try SQLiteStagingStore().write(
    StagingContents(
      stagingID: stageID, tables: tables, recordCount: manifest.recordCount,
      fieldCount: manifest.fieldCount, opaqueByteCount: manifest.opaqueByteCount),
    manifest: manifest,
    sourceSizeBytes: 0, limitsDescription: StagingLimits.standard.stableDescription, to: url)
  return (url, manifest, digest)
}

private func manifest() -> StagingManifest {
  StagingManifest(
    stagingID: id(0), artifactSHA256: id(1), profileID: MoneyManagerV19Adapter.observedProfileID,
    adapterVersion: MoneyManagerV19Adapter.version, tableCount: 1, recordCount: 1, fieldCount: 1,
    opaqueByteCount: 0)
}

private func transaction(_ identifier: Int, type: String, amount: String) throws
  -> MoneyManagerV19SourceRecord
{
  try record(
    "INOUTCOME", identifier,
    [
      "ASSET_UID": "synthetic-account", "CURRENCY_ISO": "USD", "DO_TYPE": type,
      "NOTE": "synthetic opaque note", "WDATE": "2025-02-03", "ZDATE": "1738547200000",
      "ZMONEY": amount,
    ])
}

private func record(_ table: String, _ identifier: Int, _ values: [String: String]) throws
  -> MoneyManagerV19SourceRecord
{
  try MoneyManagerV19SourceRecord(
    tableName: table, sourceRecordID: id(identifier),
    fields: try values.enumerated().map { offset, pair in
      try field(pair.key, pair.value, identifier * 10 + offset)
    })
}

private func field(
  _ name: String, _ value: String, _ identifier: Int,
  storageClass: CanonicalFieldStorageClass = .text
) throws -> MoneyManagerV19SourceField {
  try MoneyManagerV19SourceField(
    name: name, value: value,
    provenance: .init(
      artifactSHA256: id(1), profileID: MoneyManagerV19Adapter.observedProfileID,
      adapterVersion: MoneyManagerV19Adapter.version,
      locator: .init(table: "synthetic", recordKey: "synthetic", columnName: name),
      deterministicID: id(identifier)), declaredType: "TEXT", storageClass: storageClass)
}

private func id(_ integer: Int) -> String { String(format: "%064x", integer) }

private func withAdapterDatabase(
  _ url: URL, _ body: (OpaquePointer) throws -> Void
) throws {
  var database: OpaquePointer?
  guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
    let database
  else { throw AdapterTestFailure.sqlite }
  defer { sqlite3_close(database) }
  try body(database)
}

private func mutateAdapterStageSameInode(_ url: URL) throws {
  var before = stat()
  guard lstat(url.path, &before) == 0 else { throw AdapterTestFailure.sqlite }
  try withAdapterDatabase(url) { database in
    try executeAdapterTestSQL(
      database,
      "UPDATE staged_field SET payload=CAST('mutated!!' AS BLOB) WHERE column_name='NOTE'")
  }
  var after = stat()
  guard lstat(url.path, &after) == 0, before.st_dev == after.st_dev,
    before.st_ino == after.st_ino, before.st_size == after.st_size,
    before.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec
      || before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec
      || before.st_ctimespec.tv_sec != after.st_ctimespec.tv_sec
      || before.st_ctimespec.tv_nsec != after.st_ctimespec.tv_nsec
  else { throw AdapterTestFailure.sqlite }
}

private func canonicalTableCounts(_ url: URL) throws -> [String: Int] {
  let tables = [
    "economic_event", "import_receipt", "provenance_reference", "receipt_event",
    "event_source_binding", "sidecar_reference", "receipt_sidecar",
    "receipt_preservation_anchor", "receipt_preservation_payload",
    "receipt_preservation_membership",
  ]
  var counts: [String: Int] = [:]
  try withAdapterDatabase(url) { database in
    for table in tables {
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(database, "SELECT count(*) FROM \(table)", -1, &statement, nil)
        == SQLITE_OK, let statement
      else { throw AdapterTestFailure.sqlite }
      defer { sqlite3_finalize(statement) }
      guard sqlite3_step(statement) == SQLITE_ROW else { throw AdapterTestFailure.sqlite }
      counts[table] = Int(sqlite3_column_int64(statement, 0))
    }
  }
  return counts
}

private func rehashSyntheticReceipt(
  _ database: OpaquePointer, receiptID: String
) throws {
  var preservationComponents = ["ledger-atlas/receipt-owned-preservation-set/v4"]
  let membershipRows = try adapterTestTextRows(
    database,
    sql: """
      SELECT idempotency_key, source_subject_id, subject_kind, anchor_id, anchor_subject_id,
             anchor_subject_kind, payload_id
      FROM receipt_preservation_membership
      WHERE idempotency_key='\(receiptID)' ORDER BY source_subject_id
      """)
  for row in membershipRows {
    preservationComponents.append(contentsOf: try row.prefix(6).map { try #require($0) })
    appendAdapterTestOptional(row[6], to: &preservationComponents)
  }
  let anchorRows = try adapterTestTextRows(
    database,
    sql: """
      SELECT a.anchor_id, a.idempotency_key, a.source_subject_id, a.subject_kind, a.artifact_sha256,
             a.profile_id, a.adapter_version, a.container_member, a.source_table,
             a.source_record_key
      FROM receipt_preservation_membership m
      JOIN receipt_preservation_anchor a ON a.idempotency_key=m.idempotency_key
        AND a.anchor_id=m.anchor_id
      WHERE m.idempotency_key='\(receiptID)' AND m.subject_kind IN ('table','record')
      ORDER BY a.anchor_id
      """)
  for row in anchorRows {
    preservationComponents.append(contentsOf: try row.prefix(7).map { try #require($0) })
    appendAdapterTestOptional(row[7], to: &preservationComponents)
    preservationComponents.append(try #require(row[8]))
    appendAdapterTestOptional(row[9], to: &preservationComponents)
  }
  var payloadStatement: OpaquePointer?
  let payloadSQL = """
    SELECT x.payload_id, x.idempotency_key, x.anchor_id, x.source_subject_id,
           x.format_version, x.declared_type, x.storage_class, x.payload,
           p.artifact_sha256, p.profile_id, p.adapter_version, p.container_member,
           p.source_table, p.source_record_key, p.source_column_ordinal,
           p.source_column_name, x.provenance_id
    FROM receipt_preservation_membership m
    JOIN receipt_preservation_payload x ON x.idempotency_key=m.idempotency_key
      AND x.payload_id=m.payload_id
    JOIN provenance_reference p ON p.provenance_id=x.provenance_id
    WHERE m.idempotency_key='\(receiptID)' AND m.subject_kind='field'
    ORDER BY x.payload_id
    """
  guard sqlite3_prepare_v2(database, payloadSQL, -1, &payloadStatement, nil) == SQLITE_OK,
    let payloadStatement
  else { throw AdapterTestFailure.sqlite }
  defer { sqlite3_finalize(payloadStatement) }
  while sqlite3_step(payloadStatement) == SQLITE_ROW {
    let payloadCount = Int(sqlite3_column_bytes(payloadStatement, 7))
    let payload =
      payloadCount == 0
      ? Data()
      : Data(bytes: sqlite3_column_blob(payloadStatement, 7)!, count: payloadCount)
    let payloadHash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    func required(_ index: Int32) throws -> String {
      try #require(adapterTestColumnString(payloadStatement, index))
    }
    preservationComponents.append(contentsOf: try (0...4).map { try required(Int32($0)) })
    appendAdapterTestOptional(adapterTestColumnString(payloadStatement, 5), to: &preservationComponents)
    preservationComponents.append(contentsOf: [try required(6), payloadHash])
    preservationComponents.append(contentsOf: try (8...10).map { try required(Int32($0)) })
    appendAdapterTestOptional(adapterTestColumnString(payloadStatement, 11), to: &preservationComponents)
    preservationComponents.append(contentsOf: [try required(12), try required(13)])
    appendAdapterTestOptional(adapterTestColumnString(payloadStatement, 14), to: &preservationComponents)
    appendAdapterTestOptional(adapterTestColumnString(payloadStatement, 15), to: &preservationComponents)
    preservationComponents.append(try required(16))
  }
  let preservationHash = CanonicalCommitDigest.hash(preservationComponents)
  let receiptRows = try adapterTestTextRows(
    database,
    sql: """
      SELECT idempotency_key, staging_digest, artifact_sha256, profile_id,
             adapter_version, event_set_hash, event_count, schema_version
      FROM import_receipt WHERE idempotency_key='\(receiptID)'
      """)
  let receipt = try #require(receiptRows.first)
  let eventHash = CanonicalCommitDigest.hash([CanonicalCommitDigest.eventSetPrefix])
  let integrity = CanonicalCommitDigest.hash(
    ["ledger-atlas/canonical-receipt-integrity/v6"] + receipt.compactMap { $0 }
      + [eventHash, preservationHash])
  try executeAdapterTestSQL(
    database,
    "UPDATE import_receipt SET reconciliation_hash='\(integrity)' WHERE idempotency_key='\(receiptID)'"
  )
}

private func appendAdapterTestOptional(_ value: String?, to components: inout [String]) {
  if let value {
    components.append(contentsOf: ["optional:some", value])
  } else {
    components.append("optional:none")
  }
}

private func adapterTestColumnString(_ statement: OpaquePointer, _ index: Int32) -> String? {
  guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
  let count = Int(sqlite3_column_bytes(statement, index))
  if count == 0 { return "" }
  guard let bytes = sqlite3_column_text(statement, index) else { return nil }
  return String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8)
}

private func adapterTestTextRows(
  _ database: OpaquePointer, sql: String
) throws -> [[String?]] {
  var statement: OpaquePointer?
  guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
    throw AdapterTestFailure.sqlite
  }
  defer { sqlite3_finalize(statement) }
  var rows: [[String?]] = []
  while true {
    let result = sqlite3_step(statement)
    if result == SQLITE_DONE { return rows }
    guard result == SQLITE_ROW else { throw AdapterTestFailure.sqlite }
    rows.append(
      (0..<sqlite3_column_count(statement)).map { index in
        adapterTestColumnString(statement, index)
      })
  }
}

private func executeAdapterTestSQL(_ database: OpaquePointer, _ sql: String) throws {
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
    throw AdapterTestFailure.sqlite
  }
}

private func adapterTestCanonicalChecksum(_ url: URL) throws -> String {
  var hasher = SHA256()
  func append(_ data: Data) {
    var length = UInt64(data.count).bigEndian
    withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
    hasher.update(data: data)
  }
  append(Data("ledger-atlas/canonical-checksum/v1".utf8))
  try withAdapterDatabase(url) { database in
    for sql in CanonicalLedgerSchema.checksumQueries {
      append(Data(sql.utf8))
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
        let statement
      else { throw AdapterTestFailure.sqlite }
      defer { sqlite3_finalize(statement) }
      while true {
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { break }
        guard result == SQLITE_ROW else { throw AdapterTestFailure.sqlite }
        for column in 0..<sqlite3_column_count(statement) {
          switch sqlite3_column_type(statement, column) {
          case SQLITE_NULL:
            append(Data([0]))
          case SQLITE_INTEGER:
            append(Data([1]))
            append(Data(String(sqlite3_column_int64(statement, column)).utf8))
          case SQLITE_TEXT, SQLITE_BLOB:
            append(Data([sqlite3_column_type(statement, column) == SQLITE_TEXT ? 2 : 3]))
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count == 0 || sqlite3_column_blob(statement, column) != nil else {
              throw AdapterTestFailure.sqlite
            }
            append(
              count == 0
                ? Data()
                : Data(bytes: sqlite3_column_blob(statement, column)!, count: count))
          default:
            throw AdapterTestFailure.sqlite
          }
        }
      }
    }
  }
  return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private enum AdapterTestFailure: Error { case sqlite }
