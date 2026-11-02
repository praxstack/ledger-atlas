import Foundation
import LedgerCore
import Testing

@Suite("Canonical persistence models")
struct CanonicalPersistenceModelsTests {
  @Test("receipt digests keep their frozen length-prefixed encoding")
  func receiptDigestEncodingIsFrozen() {
    // Values computed independently (SHA-256 over an 8-byte big-endian length plus UTF-8 bytes
    // per component). Stored receipts depend on this exact encoding.
    #expect(
      CanonicalReceiptDigest.hash(["", "ledger-atlas", "₹ 1,250.00", "naïve 🧾"])
        == "01854d68f6ec1bdcd89195520d596e2944239fa550f93cfad7aef1f94aa6ba75")
    #expect(
      CanonicalReceiptDigest.sha256(Data("receipt".utf8))
        == "6f32860910ca0fb2a20c7fda143666b09dbf8db5238195c90a586fb542ff0cad")
  }

  @Test("hex encoding matches the per-byte %02x format for every byte")
  func hexMatchesFormatForEveryByte() {
    // Every persisted digest goes through this encoder, so it must stay byte-identical to the
    // String(format:) output it replaced.
    let allBytes = (0...255).map { UInt8($0) }
    #expect(
      CanonicalReceiptDigest.hex(allBytes)
        == allBytes.map { String(format: "%02x", $0) }.joined())
    #expect(CanonicalReceiptDigest.hex([UInt8]()) == "")
  }

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

  @Test("lifecycle upgrade chain is contiguous, additive, and ends at the current schema")
  func lifecycleUpgradeChain() throws {
    let steps = CanonicalLedgerSchema.lifecycleUpgradeSteps
    #expect(!steps.isEmpty)
    #expect(steps.last?.to == CanonicalLedgerSchema.currentRelease)
    for (step, next) in zip(steps, steps.dropFirst()) { #expect(step.to == next.from) }
    for step in steps {
      #expect(step.to.version > step.from.version)
      #expect(
        CanonicalLedgerSchema.schemaFingerprint(for: step.from.objects) == step.from.fingerprint)
      // Additive only: every earlier object survives unchanged into the next release.
      #expect(step.from.objects.allSatisfy { step.to.objects.contains($0) })
      #expect(step.statements.count == step.to.objects.count - step.from.objects.count)
      let path = try #require(CanonicalLedgerSchema.lifecycleUpgradePath(from: step.from))
      #expect(path.last?.to == CanonicalLedgerSchema.currentRelease)
    }
    let v10 = try #require(
      CanonicalLedgerSchema.lifecycleLegacyRelease(
        version: 10, fingerprint: CanonicalLedgerSchema.legacyV10Fingerprint))
    #expect(v10 == CanonicalLedgerSchema.legacyV10Release)
    #expect(CanonicalLedgerSchema.lifecycleUpgradePath(from: v10)?.count == 3)
    let v11 = try #require(
      CanonicalLedgerSchema.lifecycleLegacyRelease(
        version: 11, fingerprint: CanonicalLedgerSchema.legacyV11Fingerprint))
    #expect(v11 == CanonicalLedgerSchema.legacyV11Release)
    #expect(CanonicalLedgerSchema.lifecycleUpgradePath(from: v11)?.count == 2)
    let v12 = try #require(
      CanonicalLedgerSchema.lifecycleLegacyRelease(
        version: 12, fingerprint: CanonicalLedgerSchema.legacyV12Fingerprint))
    #expect(v12 == CanonicalLedgerSchema.legacyV12Release)
    #expect(CanonicalLedgerSchema.lifecycleUpgradePath(from: v12)?.count == 1)
    #expect(
      CanonicalLedgerSchema.lifecycleLegacyRelease(
        version: 10, fingerprint: CanonicalLedgerSchema.legacyV8Fingerprint) == nil)
    #expect(
      CanonicalLedgerSchema.lifecycleLegacyRelease(
        version: CanonicalLedgerSchema.version, fingerprint: CanonicalLedgerSchema.fingerprint)
        == nil)
    #expect(
      CanonicalLedgerSchema.lifecycleUpgradePath(from: CanonicalLedgerSchema.currentRelease)
        == nil)
  }

  @Test("canonical schema has an exact stable fingerprint and no permissive DDL")
  func canonicalSchemaFingerprint() {
    #expect(CanonicalIdentifier.isValid(CanonicalLedgerSchema.fingerprint))
    #expect(
      CanonicalLedgerSchema.legacyV8Fingerprint
        == "f5526a4621eeb0e780851c3b50444d0c387f48ea953f1c1860da3204c8db91dc")
    #expect(CanonicalLedgerSchema.legacyV8Fingerprint != CanonicalLedgerSchema.fingerprint)
    #expect(CanonicalLedgerSchema.version == 13)
    #expect(
      CanonicalLedgerSchema.legacyV10Fingerprint
        == "aca9d078dd357cd64a6fe209e04fb7e3ac724525cf15b8c313e0b8177d2b6926")
    #expect(
      CanonicalLedgerSchema.schemaFingerprint(for: CanonicalLedgerSchema.legacyV10Objects)
        == CanonicalLedgerSchema.legacyV10Fingerprint)
    #expect(CanonicalLedgerSchema.legacyV10Objects.count == 31)
    #expect(
      CanonicalLedgerSchema.legacyV11Fingerprint
        == "513702f73c663ad72e0af52304e9f4eabf3ba31aafae259abdbd3d0f74d73fc4")
    #expect(
      CanonicalLedgerSchema.schemaFingerprint(for: CanonicalLedgerSchema.legacyV11Objects)
        == CanonicalLedgerSchema.legacyV11Fingerprint)
    #expect(CanonicalLedgerSchema.legacyV11Objects.count == 35)
    #expect(
      CanonicalLedgerSchema.legacyV12Fingerprint
        == "c6b67526e3c6d26c430e9dbfbdcdb39bd0517172a0a50369e86ea94eb13b5355")
    #expect(
      CanonicalLedgerSchema.schemaFingerprint(for: CanonicalLedgerSchema.legacyV12Objects)
        == CanonicalLedgerSchema.legacyV12Fingerprint)
    #expect(CanonicalLedgerSchema.legacyV12Objects.count == 43)
    #expect(CanonicalLedgerSchema.expectedObjects.count == 47)
    #expect(Set(CanonicalLedgerSchema.expectedObjects.map(\.name)).count == 47)
    #expect(
      Set(CanonicalLedgerSchema.expectedObjects.map(\.name)).isSuperset(of: [
        "receipt_preservation_anchor", "receipt_preservation_payload",
        "receipt_preservation_membership",
        "ledger_origin", "ledger_account", "ledger_category", "ledger_transaction",
        "ledger_transaction_revision", "ledger_transaction_effect",
        "ledger_transaction_source_literal", "ledger_transaction_link",
        "ledger_category_tree", "ledger_account_group", "ledger_account_preferences",
        "ledger_tag", "ledger_revision_tag", "ledger_transaction_template",
        "ledger_template_tag", "ledger_memo", "economic_event_transfer",
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
    #expect(migration == CanonicalLedgerSchema.v8ToV9MigrationStatements)
    #expect(CanonicalLedgerSchema.v8ToV9MigrationStatements.count == 16)
    #expect(CanonicalLedgerSchema.v9ToV10MigrationStatements.count == 3)
    #expect(CanonicalLedgerSchema.v10ToV11MigrationStatements.count == 4)
    #expect(
      CanonicalLedgerSchema.additiveMigrationStatements(fromVersion: 9)
        == CanonicalLedgerSchema.v9ToV10MigrationStatements)
    #expect(
      CanonicalLedgerSchema.additiveMigrationStatements(fromVersion: 10)
        == CanonicalLedgerSchema.v10ToV11MigrationStatements)
    #expect(CanonicalLedgerSchema.v11ToV12MigrationStatements.count == 8)
    #expect(
      CanonicalLedgerSchema.additiveMigrationStatements(fromVersion: 11)
        == CanonicalLedgerSchema.v11ToV12MigrationStatements)
    #expect(CanonicalLedgerSchema.v12ToV13MigrationStatements.count == 4)
    #expect(
      CanonicalLedgerSchema.v12ToV13MigrationStatements.first?.hasPrefix(
        "CREATE TABLE ledger_receipt_attachment") == true)
    #expect(
      CanonicalLedgerSchema.additiveMigrationStatements(fromVersion: 12)
        == CanonicalLedgerSchema.v12ToV13MigrationStatements)
    #expect(CanonicalLedgerSchema.additiveMigrationStatements(fromVersion: 13) == [])
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

  @Test("v12 adds tags, templates, memos and transfer pairs as new tables only")
  func v12Annotations() {
    let objects = Dictionary(
      uniqueKeysWithValues: CanonicalLedgerSchema.expectedObjects.map { ($0.name, $0.ddl) })
    #expect(CanonicalLedgerSchema.legacyV11Objects.allSatisfy {
      CanonicalLedgerSchema.expectedObjects.contains($0)
    })
    let migration = CanonicalLedgerSchema.v11ToV12MigrationStatements
    #expect(migration.allSatisfy { $0.hasPrefix("CREATE") })
    #expect(migration.prefix(6).allSatisfy { $0.hasPrefix("CREATE TABLE") })
    #expect((objects["ledger_tag"] ?? "").contains("lifecycle IN ('active', 'tombstoned')"))
    #expect((objects["ledger_revision_tag"] ?? "").contains("PRIMARY KEY(revision_id, tag_id)"))
    #expect(objects["ledger_revision_tag_immutable_update"] != nil)
    #expect(objects["ledger_revision_tag_immutable_delete"] != nil)
    let template = objects["ledger_transaction_template"] ?? ""
    #expect(template.contains("kind IN ('income', 'expense', 'transfer')"))
    #expect(template.contains("CHECK(kind != 'transfer' OR category_id IS NULL)"))
    #expect((objects["ledger_template_tag"] ?? "").contains("PRIMARY KEY(template_id, tag_id)"))
    #expect((objects["ledger_memo"] ?? "").contains("local_month BETWEEN 1 AND 12"))
    let transfer = objects["economic_event_transfer"] ?? ""
    #expect(transfer.contains("debit_event_id TEXT NOT NULL UNIQUE REFERENCES economic_event"))
    #expect(transfer.contains("CHECK(debit_event_id <> credit_event_id)"))
  }

  @Test("v11 adds category-tree and account-organization storage without changing v10 objects")
  func v11Foundations() {
    let objects = Dictionary(
      uniqueKeysWithValues: CanonicalLedgerSchema.expectedObjects.map { ($0.name, $0.ddl) })
    let categoryTree = objects["ledger_category_tree"] ?? ""
    #expect(categoryTree.contains("category_id TEXT PRIMARY KEY REFERENCES ledger_category"))
    #expect(categoryTree.contains("parent_category_id TEXT REFERENCES ledger_category"))
    #expect(categoryTree.contains("display_order INTEGER NOT NULL CHECK(display_order >= 0)"))
    #expect(categoryTree.contains("hidden INTEGER NOT NULL CHECK(hidden IN (0, 1))"))
    #expect(
      categoryTree.contains("parent_category_id IS NULL OR parent_category_id != category_id"))

    let groups = objects["ledger_account_group"] ?? ""
    #expect(groups.contains("group_id TEXT PRIMARY KEY"))
    #expect(groups.contains("display_order INTEGER NOT NULL CHECK(display_order >= 0)"))
    #expect(groups.contains("lifecycle TEXT NOT NULL CHECK(lifecycle IN ('active', 'tombstoned'))"))

    let preferences = objects["ledger_account_preferences"] ?? ""
    #expect(preferences.contains("account_id TEXT PRIMARY KEY REFERENCES ledger_account"))
    #expect(preferences.contains("group_id TEXT REFERENCES ledger_account_group"))
    #expect(preferences.contains("hidden INTEGER NOT NULL CHECK(hidden IN (0, 1))"))
    #expect(
      preferences.contains("include_in_totals INTEGER NOT NULL CHECK(include_in_totals IN (0, 1))"))
    #expect(preferences.contains("variant TEXT NOT NULL"))
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
