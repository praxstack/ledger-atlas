import Foundation
import LedgerCore
import Testing

@Suite("Canonical persistence models")
struct CanonicalPersistenceModelsTests {
  @Test("stable event identifiers are deterministic and effect-specific")
  func stableEventIdentifiers() throws {
    let sourceRecordID = String(repeating: "a", count: 64)
    let first = try StableCanonicalID.event(sourceRecordID: sourceRecordID, effectOrdinal: 0)
    let repeated = try StableCanonicalID.event(sourceRecordID: sourceRecordID, effectOrdinal: 0)
    let second = try StableCanonicalID.event(sourceRecordID: sourceRecordID, effectOrdinal: 1)
    #expect(first == repeated)
    #expect(first != second)
    #expect(CanonicalIdentifier.isValid(first))
  }

  @Test("invalid identifiers fail with content-free errors")
  func invalidIdentifiersAreRedacted() {
    let sentinel = "PRIVATE_CANONICAL_SENTINEL"
    do {
      _ = try StableCanonicalID.event(sourceRecordID: sentinel, effectOrdinal: 0)
      Issue.record("expected invalid identifier")
    } catch {
      #expect(!String(describing: error).contains(sentinel))
      #expect(error as? CanonicalPersistenceError == .invalidIdentifier)
    }
  }

  @Test("canonical schema has an exact stable fingerprint and no permissive DDL")
  func canonicalSchemaFingerprint() {
    #expect(CanonicalIdentifier.isValid(CanonicalLedgerSchema.fingerprint))
    #expect(
      CanonicalLedgerSchema.legacyV8Fingerprint
        == "f5526a4621eeb0e780851c3b50444d0c387f48ea953f1c1860da3204c8db91dc")
    #expect(CanonicalLedgerSchema.legacyV8Fingerprint != CanonicalLedgerSchema.fingerprint)
    #expect(CanonicalLedgerSchema.version == 10)
    #expect(CanonicalLedgerSchema.expectedObjects.count == 31)
    #expect(Set(CanonicalLedgerSchema.expectedObjects.map(\.name)).count == 31)
    #expect(
      Set(CanonicalLedgerSchema.expectedObjects.map(\.name)).isSuperset(of: [
        "receipt_preservation_anchor", "receipt_preservation_payload",
        "receipt_preservation_membership",
        "ledger_origin", "ledger_account", "ledger_category", "ledger_transaction",
        "ledger_transaction_revision", "ledger_transaction_effect",
        "ledger_transaction_source_literal", "ledger_transaction_link",
      ]))
    #expect(
      CanonicalLedgerSchema.creationStatements.allSatisfy {
        !$0.localizedCaseInsensitiveContains("IF NOT EXISTS")
      })
  }

  @Test("schema v9 appends the LedgerDomain tables without rewriting v8 imports")
  func v9ApplicationSchemaMigration() {
    guard let migration = CanonicalLedgerSchema.additiveMigrationStatements(fromVersion: 8) else {
      Issue.record("missing v8-to-v9 migration")
      return
    }
    #expect(
      migration
        == CanonicalLedgerSchema.v8ToV9MigrationStatements
        + CanonicalLedgerSchema.v9ToV10MigrationStatements)
    #expect(migration.count == 19)
    #expect(CanonicalLedgerSchema.v8ToV9MigrationStatements.count == 16)
    #expect(CanonicalLedgerSchema.v9ToV10MigrationStatements.count == 3)
    #expect(
      CanonicalLedgerSchema.additiveMigrationStatements(fromVersion: 9)
        == CanonicalLedgerSchema.v9ToV10MigrationStatements)
    #expect(CanonicalLedgerSchema.additiveMigrationStatements(fromVersion: 10) == [])
    #expect(CanonicalLedgerSchema.additiveMigrationStatements(fromVersion: 7) == nil)
    #expect(migration.allSatisfy { $0.localizedCaseInsensitiveContains("CREATE") })
    #expect(migration.allSatisfy { !$0.localizedCaseInsensitiveContains("ALTER TABLE") })
    #expect(migration.allSatisfy { !$0.localizedCaseInsensitiveContains("DROP TABLE") })
    #expect(CanonicalLedgerSchema.legacyV8Objects.count == 12)
    #expect(
      CanonicalLedgerSchema.legacyV8Objects.map(\.name).sorted()
        == CanonicalLedgerSchema.legacyV8TableNames)
    #expect(CanonicalLedgerSchema.legacyV8Objects.map(\.name).contains("ledger_meta"))
    #expect(
      CanonicalLedgerSchema.legacyV8Objects.allSatisfy {
        !$0.name.hasPrefix("ledger_") || $0.name == "ledger_meta"
      })
  }

  @Test("v9 application tables retain exact domain columns and immutable revision history")
  func v9ApplicationSchemaContracts() {
    let objects = Dictionary(
      uniqueKeysWithValues: CanonicalLedgerSchema.expectedObjects.map {
        ($0.name, $0.ddl)
      })
    #expect(objects["ledger_transaction_revision"]?.contains("predecessor_id TEXT") == true)
    #expect(objects["ledger_transaction_revision"]?.contains("rounding_policy TEXT") == true)
    #expect(objects["ledger_transaction_effect"]?.contains("amount_literal TEXT NOT NULL") == true)
    #expect(objects["ledger_transaction_source_literal"]?.contains("literal TEXT NOT NULL") == true)
    #expect(objects["ledger_transaction_link"]?.contains("kind TEXT NOT NULL") == true)
    for name in [
      "ledger_transaction_revision", "ledger_transaction_effect",
      "ledger_transaction_source_literal", "ledger_transaction_link",
    ] {
      #expect(objects["\(name)_immutable_update"]?.contains("BEFORE UPDATE ON \(name)") == true)
      #expect(objects["\(name)_immutable_delete"]?.contains("BEFORE DELETE ON \(name)") == true)
    }
    #expect(
      CanonicalLedgerSchema.checksumQueries.contains {
        $0.contains("FROM ledger_transaction_revision")
      })
  }

  @Test("receipt-owned anchors and payloads keep source identity separate from canonical identity")
  func receiptOwnedPreservationModels() throws {
    let stagingID = String(repeating: "a", count: 64)
    let recordID = String(repeating: "b", count: 64)
    let fieldID = String(repeating: "c", count: 64)
    let artifact = String(repeating: "d", count: 64)
    let anchorID = try StableCanonicalID.preservationAnchor(
      stagingID: stagingID, sourceSubjectID: recordID, kind: .record)
    let payloadBytes = Data("synthetic opaque".utf8)
    let payloadID = try StableCanonicalID.preservationPayload(
      receiptID: stagingID, anchorID: anchorID, sourceSubjectID: fieldID,
      formatVersion: 1, declaredType: "TEXT", storageClass: .text, payload: payloadBytes)
    let provenance = FieldProvenance(
      artifactSHA256: artifact, profileID: "synthetic-profile",
      adapterVersion: "synthetic-adapter",
      locator: SourceLocator(
        table: "synthetic_support", recordKey: "synthetic-record", columnOrdinal: 0,
        columnName: "opaque"), deterministicID: fieldID)
    let anchor = try CanonicalReceiptOwnedAnchor(
      anchorID: anchorID, receiptID: stagingID, sourceSubjectID: recordID, subjectKind: .record,
      artifactSHA256: artifact, profileID: "synthetic-profile",
      adapterVersion: "synthetic-adapter", containerMember: nil,
      sourceTable: "synthetic_support", sourceRecordKey: "synthetic-record")
    let payload = try CanonicalReceiptOwnedPayload(
      payloadID: payloadID, receiptID: stagingID, anchorID: anchorID, sourceSubjectID: fieldID,
      formatVersion: 1, declaredType: "TEXT", storageClass: .text,
      payload: payloadBytes, provenance: provenance)

    #expect(anchor.anchorID != anchor.sourceSubjectID)
    #expect(payload.payloadID != payload.sourceSubjectID)
    #expect(payload.anchorID == anchor.anchorID)
    let absentTypePayloadID = try StableCanonicalID.preservationPayload(
      receiptID: stagingID, anchorID: anchorID, sourceSubjectID: fieldID,
      formatVersion: 1, declaredType: nil, storageClass: .text,
      payload: payloadBytes)
    let embeddedNULPayloadID = try StableCanonicalID.preservationPayload(
      receiptID: stagingID, anchorID: anchorID, sourceSubjectID: fieldID,
      formatVersion: 1, declaredType: "\u{0}", storageClass: .text,
      payload: payloadBytes)
    #expect(embeddedNULPayloadID != absentTypePayloadID)
    #expect(
      (try StableCanonicalID.preservationAnchor(
        stagingID: stagingID, sourceSubjectID: recordID, kind: .record)) == anchorID)
    #expect(throws: CanonicalPersistenceError.invalidReceiptOwnedPreservation) {
      _ = try CanonicalReceiptOwnedAnchor(
        anchorID: anchorID, receiptID: stagingID, sourceSubjectID: recordID, subjectKind: .table,
        artifactSHA256: artifact, profileID: "synthetic-profile",
        adapterVersion: "synthetic-adapter", containerMember: nil,
        sourceTable: "synthetic_support", sourceRecordKey: "invented-record")
    }
  }
}
