import CSQLite
import Foundation
import LedgerAdapterSemantics
import LedgerCore

/// Replays persisted native-ledger rows through the domain constructors.
/// Structural SQLite checks alone cannot establish financial validity.
package enum CanonicalLedgerHealth {
  package static func isHealthy(_ database: OpaquePointer, trustKey: Data? = nil) -> Bool {
    (try? validate(database, trustKey: trustKey)) != nil
  }

  /// `verifyingReceiptImages` re-hashes every stored receipt image. Opening, restoring and
  /// backing up do that; a write skips it, since receipt bytes can't change after insert and
  /// the store hashes them when they go in.
  static func validate(
    _ database: OpaquePointer, trustKey: Data? = nil, verifyingReceiptImages: Bool = true
  ) throws {
    try validateImportGraph(database, trustKey: trustKey)
    try validateReceiptAttachments(database, verifyingImages: verifyingReceiptImages)
    _ = try readSnapshot(database)
  }

  /// Receipt attachments (schema v13). Absent before v13.
  private static func validateReceiptAttachments(_ database: OpaquePointer, verifyingImages: Bool)
    throws
  {
    guard
      !(try rows(
        database,
        "SELECT 1 FROM sqlite_schema WHERE type='table' AND name='ledger_receipt_attachment'",
        { _ in () })).isEmpty
    else { return }
    let invalidQueries = [
      "SELECT 1 FROM ledger_receipt_attachment WHERE typeof(bytes)<>'blob' OR byte_count<>length(bytes) OR attachment_id GLOB '*[^0-9a-f]*' OR sha256 GLOB '*[^0-9a-f]*' OR transaction_id GLOB '*[^0-9a-f]*'",
      // A link may point at a deleted transaction, but never at nothing.
      "SELECT 1 FROM ledger_receipt_attachment r WHERE r.transaction_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM ledger_transaction t WHERE t.transaction_id=r.transaction_id) AND NOT EXISTS (SELECT 1 FROM economic_event e WHERE e.event_id=r.transaction_id) AND NOT EXISTS (SELECT 1 FROM economic_event_transfer x WHERE x.transfer_id=r.transaction_id)",
      "SELECT 1 WHERE (SELECT coalesce(sum(length(bytes)),0) FROM ledger_receipt_attachment)>\(LedgerReceiptAttachment.maximumTotalBytes)",
    ]
    for query in invalidQueries where try !rows(database, query, { _ in () }).isEmpty {
      throw HealthError.invalid
    }
    guard verifyingImages else { return }
    let ids = try rows(
      database, "SELECT attachment_id FROM ledger_receipt_attachment ORDER BY attachment_id",
      { $0.text(0) })
    // One image at a time keeps memory to a single receipt.
    for id in ids {
      let checked = try rows(
        database,
        "SELECT attachment_id, sha256, media_type, origin_id, bytes FROM ledger_receipt_attachment WHERE attachment_id='\(id)'"
      ) { row -> Bool in
        let bytes = row.blob(4)
        let origin = try LedgerOrigin(id: row.text(3), label: "receipt-check")
        return row.blobColumns([4])
          && LedgerReceiptAttachment.digest(bytes) == row.text(1)
          && LedgerReceiptAttachment.MediaType(sniffing: bytes)?.rawValue == row.text(2)
          && LedgerReceiptAttachment.id(origin: origin, sha256: row.text(1)) == row.text(0)
      }
      guard checked == [true] else { throw HealthError.invalid }
    }
  }

  static func readSnapshot(_ database: OpaquePointer) throws -> LedgerStore.LedgerReadSnapshot {
    try validateSourceLiteralOrdinals(database)
    let origins = try Dictionary(
      uniqueKeysWithValues: rows(
        database, "SELECT origin_id, label, provenance_id FROM main.ledger_origin"
      ) { row in
        let value = try LedgerOrigin(
          id: row.text(0), label: row.text(1), provenanceID: row.optionalText(2))
        return (value.id, value)
      })
    let v11Tables = Set(
      try rows(
        database,
        "SELECT name FROM sqlite_schema WHERE type='table' AND name IN ('ledger_account_group', 'ledger_account_preferences', 'ledger_category_tree')"
      ) { $0.text(0) })
    let accountGroups: [String: LedgerAccountGroup]
    if v11Tables.contains("ledger_account_group") {
      accountGroups = try Dictionary(
        uniqueKeysWithValues: rows(
          database,
          "SELECT group_id, name, display_order, lifecycle FROM main.ledger_account_group"
        ) { row in
          let group = try LedgerAccountGroup(
            id: row.text(0), name: row.text(1), displayOrder: row.int(2),
            lifecycle: try enumValue(LedgerLifecycleState.self, row.text(3)))
          return (group.id, group)
        })
    } else {
      accountGroups = [:]
    }
    let accountPreferences: [String: AccountPreference]
    if v11Tables.contains("ledger_account_preferences") {
      accountPreferences = try Dictionary(
        uniqueKeysWithValues: rows(
          database,
          "SELECT account_id, group_id, display_order, hidden, include_in_totals, variant FROM main.ledger_account_preferences"
        ) { row in
          guard row.int(3) == 0 || row.int(3) == 1,
            row.int(4) == 0 || row.int(4) == 1,
            let variant = LedgerAccountVariant(rawValue: row.text(5))
          else { throw HealthError.invalid }
          return (
            row.text(0),
            AccountPreference(
              groupID: row.optionalText(1), displayOrder: row.int(2), hidden: row.int(3) == 1,
              includeInTotals: row.int(4) == 1, variant: variant))
        })
    } else {
      accountPreferences = [:]
    }
    let accounts = try Dictionary(
      uniqueKeysWithValues: rows(
      database,
      "SELECT account_id, name, currency_unit, origin_id, lifecycle FROM main.ledger_account"
      ) { row in
        let preference = accountPreferences[row.text(0)] ?? .defaults
        let lifecycle = try enumValue(LedgerLifecycleState.self, row.text(4))
        if let groupID = preference.groupID {
          guard let group = accountGroups[groupID] else { throw HealthError.invalid }
          if lifecycle == .active { guard group.lifecycle == .active else { throw HealthError.invalid } }
        }
        let value = try LedgerAccount(
          id: row.text(0), name: row.text(1), currencyUnit: row.text(2),
          origin: try require(origins[row.text(3)]),
          lifecycle: lifecycle,
          groupID: preference.groupID, displayOrder: preference.displayOrder,
          hidden: preference.hidden, includeInTotals: preference.includeInTotals,
          variant: preference.variant)
        return (value.id, value)
      })
    let categoryTrees: [String: CategoryTree]
    if v11Tables.contains("ledger_category_tree") {
      categoryTrees = try Dictionary(
        uniqueKeysWithValues: rows(
          database,
          "SELECT category_id, parent_category_id, display_order, hidden FROM main.ledger_category_tree"
        ) { row in
          guard row.int(3) == 0 || row.int(3) == 1 else { throw HealthError.invalid }
          return (
            row.text(0),
            CategoryTree(
              parentID: row.optionalText(1), displayOrder: row.int(2), hidden: row.int(3) == 1))
        })
    } else {
      categoryTrees = [:]
    }
    let categories = try Dictionary(
      uniqueKeysWithValues: rows(
        database, "SELECT category_id, name, kind, origin_id, lifecycle FROM main.ledger_category"
      ) { row in
        let tree = categoryTrees[row.text(0)] ?? .defaults
        let value = try LedgerCategory(
          id: row.text(0), name: row.text(1),
          kind: try enumValue(LedgerCategoryKind.self, row.text(2)),
          origin: try require(origins[row.text(3)]),
          lifecycle: try enumValue(LedgerLifecycleState.self, row.text(4)),
          parentID: tree.parentID, displayOrder: tree.displayOrder, hidden: tree.hidden)
        return (value.id, value)
      })
    for category in categories.values {
      if let parentID = category.parentID {
        guard let parent = categories[parentID] else { throw HealthError.invalid }
        if category.lifecycle == .active {
          guard parent.lifecycle == .active, !parent.hidden else { throw HealthError.invalid }
        }
      }
      var seen: Set<String> = []
      var cursor: String? = category.id
      while let current = cursor {
        guard seen.insert(current).inserted else { throw HealthError.invalid }
        cursor = categories[current]?.parentID
      }
    }
    let effects = try grouped(
      database,
      "SELECT revision_id, account_id, direction, amount_literal, currency_unit FROM main.ledger_transaction_effect ORDER BY revision_id, account_id"
    ) { row in
      let account = try require(accounts[row.text(1)])
      guard account.currencyUnit == row.text(4) else { throw HealthError.invalid }
      return try LedgerTransactionEffect(
        accountID: account.id, direction: enumValue(LedgerEffectDirection.self, row.text(2)),
        amount: CurrencyAmount(unitCode: row.text(4), amount: ExactDecimal(row.text(3))))
    }
    let literals = try grouped(
      database,
      "SELECT revision_id, field, literal, provenance_id FROM main.ledger_transaction_source_literal ORDER BY revision_id, ordinal"
    ) { row in
      try LedgerSourceLiteral(
        field: row.text(1), literal: row.text(2), provenanceID: row.optionalText(3))
    }
    var revisions: [String: LedgerTransactionRevision] = [:]
    var revisionNumbers: [String: [Int]] = [:]
    var snapshots: [LedgerTransactionSnapshot] = []
    for row in try rows(
      database,
      "SELECT revision_id, transaction_id, revision, predecessor_id, category_id, kind, instant_milliseconds, local_year, local_month, local_day, local_hour, local_minute, local_second, local_millisecond, timezone_kind, timezone_value, temporal_precision, resolved_offset_seconds, note, rounding_policy, origin_id, lifecycle, created_at_milliseconds FROM main.ledger_transaction_revision ORDER BY transaction_id, revision",
      { $0 }
    ) {
      let revisionID = row.text(0)
      let transactionID = row.text(1)
      let kind = try enumValue(LedgerTransactionKind.self, row.text(5))
      let categoryID = row.optionalText(4)
      try validateCategory(categoryID, kind: kind, categories: categories)
      let local = try SourceLocalDateTime(
        date: SourceLocalDate(year: row.int(7), month: row.int(8), day: row.int(9)),
        hour: row.int(10), minute: row.int(11), second: row.int(12), millisecond: row.int(13))
      let precision = try enumValue(SourceTemporalPrecision.self, row.text(16))
      let instant = UTCInstant(epochMilliseconds: row.int64(6))
      let temporal: SourceTemporal
      switch row.text(14) {
      case "iana":
        temporal = try SourceTemporal.validatingPersistedIANA(
          instant: instant, localDateTime: local, identifier: row.text(15), precision: precision,
          resolvedOffsetSeconds: row.int(17))
      case "fixed":
        guard let offset = Int(row.text(15)), String(offset) == row.text(15) else {
          throw HealthError.invalid
        }
        temporal = try SourceTemporal(
          instant: instant, localDateTime: local,
          timeZone: SourceTimeZone(fixedOffsetSeconds: offset), precision: precision,
          resolvedOffsetSeconds: row.int(17))
      default: throw HealthError.invalid
      }
      let rounding = try row.optionalText(19).map { try enumValue(RoundingPolicy.self, $0) }
      let draft = try LedgerTransactionDraft(
        effects: effects[revisionID] ?? [], categoryID: categoryID, kind: kind,
        occurredAt: temporal, note: row.optionalText(18), roundingPolicy: rounding,
        sourceLiterals: literals[revisionID] ?? [], origin: try require(origins[row.text(20)]))
      let value = try LedgerTransactionRevision(
        id: revisionID, transactionID: transactionID, revision: row.int(2),
        predecessorID: row.optionalText(3), draft: draft,
        lifecycle: enumValue(LedgerLifecycleState.self, row.text(21)),
        createdAt: UTCInstant(epochMilliseconds: row.int64(22)))
      guard revisions[value.id] == nil else { throw HealthError.invalid }
      revisions[value.id] = value
      revisionNumbers[transactionID, default: []].append(value.revision)
    }
    for transactionRevisions in Dictionary(grouping: revisions.values, by: \.transactionID).values {
      let ordered = transactionRevisions.sorted { $0.revision < $1.revision }
      for (index, revision) in ordered.enumerated() {
        guard revision.revision == index + 1,
          revision.predecessorID == (index == 0 ? nil : ordered[index - 1].id),
          index == 0
            || (ordered[index - 1].lifecycle == .active
              && revision.createdAt >= ordered[index - 1].createdAt)
        else { throw HealthError.invalid }
      }
    }
    let links = try rows(
      database,
      "SELECT link_id, from_transaction_id, to_transaction_id, kind FROM main.ledger_transaction_link"
    ) { row in
      try LedgerTransactionLink(
        id: row.text(0), fromTransactionID: row.text(1), toTransactionID: row.text(2),
        kind: enumValue(LedgerTransactionLinkKind.self, row.text(3)))
    }
    var linksByTransaction: [String: [LedgerTransactionLink]] = [:]
    for link in links {
      linksByTransaction[link.fromTransactionID, default: []].append(link)
      linksByTransaction[link.toTransactionID, default: []].append(link)
    }
    for row in try rows(
      database, "SELECT transaction_id, current_revision_id FROM main.ledger_transaction", { $0 })
    {
      let transactionID = row.text(0)
      let current = try require(revisions[row.text(1)])
      guard current.transactionID == transactionID,
        revisionNumbers[transactionID] == Array(1...current.revision)
      else { throw HealthError.invalid }
      snapshots.append(
        try LedgerTransactionSnapshot(
          id: transactionID, currentRevision: current,
          links: linksByTransaction[transactionID] ?? []))
    }
    return .init(
      accounts: accounts.values.sorted { $0.id < $1.id },
      accountGroups: accountGroups.values.sorted {
        ($0.displayOrder, $0.id) < ($1.displayOrder, $1.id)
      },
      transactions: snapshots.sorted {
        let lhs = $0.currentRevision.draft.occurredAt.instant
        let rhs = $1.currentRevision.draft.occurredAt.instant
        return lhs == rhs ? $0.id < $1.id : lhs > rhs
      },
      revisionHistory: revisions.values.sorted {
        ($0.transactionID, $0.revision) < ($1.transactionID, $1.revision)
      },
      undisplayedImportedEventCount: 0,
      categories: categories.values.sorted {
        ($0.displayOrder, $0.id) < ($1.displayOrder, $1.id)
      })
  }

  private struct AccountPreference {
    let groupID: String?
    let displayOrder: Int
    let hidden: Bool
    let includeInTotals: Bool
    let variant: LedgerAccountVariant

    static let defaults = AccountPreference(
      groupID: nil, displayOrder: 0, hidden: false, includeInTotals: true, variant: .standard)
  }

  private struct CategoryTree {
    let parentID: String?
    let displayOrder: Int
    let hidden: Bool

    static let defaults = CategoryTree(parentID: nil, displayOrder: 0, hidden: false)
  }

  private static func validateImportGraph(_ database: OpaquePointer, trustKey: Data?) throws {
    for row in try rows(
      database,
      "SELECT event_id, account_id, event_kind, amount_literal, currency_unit, instant_milliseconds, local_year, local_month, local_day, local_hour, local_minute, local_second, local_millisecond, timezone_kind, timezone_value, temporal_precision, resolved_offset_seconds, source_record_id, provenance_id FROM main.economic_event",
      { $0 })
    {
      guard CanonicalIdentifier.isValid(row.text(0)), CanonicalIdentifier.isValid(row.text(1)),
        CanonicalIdentifier.isValid(row.text(17)), CanonicalIdentifier.isValid(row.text(18)),
        CanonicalEventKind(rawValue: row.text(2)) != nil
      else { throw HealthError.invalid }
      _ = try CurrencyAmount(unitCode: row.text(4), amount: ExactDecimal(row.text(3)))
      let local = try SourceLocalDateTime(
        date: SourceLocalDate(year: row.int(6), month: row.int(7), day: row.int(8)),
        hour: row.int(9), minute: row.int(10), second: row.int(11), millisecond: row.int(12))
      let instant = UTCInstant(epochMilliseconds: row.int64(5))
      let precision = try enumValue(SourceTemporalPrecision.self, row.text(15))
      switch row.text(13) {
      case "iana":
        _ = try SourceTemporal.validatingPersistedIANA(
          instant: instant, localDateTime: local, identifier: row.text(14),
          precision: precision, resolvedOffsetSeconds: row.int(16))
      case "fixed":
        guard let offset = Int(row.text(14)), String(offset) == row.text(14) else {
          throw HealthError.invalid
        }
        _ = try SourceTemporal(
          instant: instant, localDateTime: local,
          timeZone: SourceTimeZone(fixedOffsetSeconds: offset), precision: precision,
          resolvedOffsetSeconds: row.int(16))
      default: throw HealthError.invalid
      }
    }

    let invalidQueries = [
      "SELECT 1 FROM import_receipt WHERE length(idempotency_key)<>64 OR idempotency_key GLOB '*[^0-9a-f]*' OR length(staging_digest)<>64 OR staging_digest GLOB '*[^0-9a-f]*' OR length(artifact_sha256)<>64 OR artifact_sha256 GLOB '*[^0-9a-f]*' OR length(reconciliation_hash)<>64 OR reconciliation_hash GLOB '*[^0-9a-f]*' OR length(event_set_hash)<>64 OR event_set_hash GLOB '*[^0-9a-f]*' OR event_count<0",
      "SELECT 1 FROM import_receipt r WHERE r.event_count<>(SELECT count(*) FROM receipt_event x WHERE x.idempotency_key=r.idempotency_key)",
      "SELECT 1 FROM economic_event e WHERE (SELECT count(*) FROM receipt_event r WHERE r.event_id=e.event_id)<>1",
      "SELECT 1 FROM economic_event e WHERE (SELECT count(*) FROM event_source_binding b WHERE b.event_id=e.event_id)<>5 OR EXISTS (SELECT 1 FROM (SELECT 'amount' semantic UNION ALL SELECT 'currency' UNION ALL SELECT 'occurred_at' UNION ALL SELECT 'account' UNION ALL SELECT 'kind') required WHERE NOT EXISTS (SELECT 1 FROM event_source_binding b WHERE b.event_id=e.event_id AND b.semantic=required.semantic))",
      "SELECT 1 FROM event_source_binding b WHERE (SELECT count(*) FROM receipt_binding r WHERE r.event_id=b.event_id AND r.semantic=b.semantic AND r.provenance_id=b.provenance_id)<>1",
      "SELECT 1 FROM receipt_binding b WHERE NOT EXISTS (SELECT 1 FROM receipt_event e WHERE e.idempotency_key=b.idempotency_key AND e.event_id=b.event_id)",
      "SELECT 1 FROM sidecar_reference s WHERE (SELECT count(*) FROM receipt_sidecar r WHERE r.sidecar_id=s.sidecar_id AND r.event_id=s.event_id AND r.provenance_id=s.provenance_id)<>1",
      "SELECT 1 FROM receipt_sidecar s WHERE NOT EXISTS (SELECT 1 FROM receipt_event e WHERE e.idempotency_key=s.idempotency_key AND e.event_id=s.event_id)",
      "SELECT 1 FROM sidecar_reference WHERE provenance_id<>sidecar_id OR format_version<>1 OR length(coalesce(declared_type,''))>1024 OR length(payload)>67108864 OR (storage_class='null' AND length(payload)<>0) OR (storage_class IN ('integer','real') AND length(payload)<>8)",
      "SELECT 1 FROM receipt_preservation_payload WHERE provenance_id<>source_subject_id OR format_version<>1 OR length(coalesce(declared_type,''))>1024 OR length(payload)>67108864 OR (storage_class='null' AND length(payload)<>0) OR (storage_class IN ('integer','real') AND length(payload)<>8)",
      "SELECT 1 WHERE (SELECT coalesce(sum(length(payload)),0) FROM sidecar_reference)+(SELECT coalesce(sum(length(payload)),0) FROM receipt_preservation_payload)>536870912",
      "SELECT 1 FROM receipt_preservation_anchor a LEFT JOIN import_receipt r ON r.idempotency_key=a.idempotency_key WHERE r.idempotency_key IS NULL OR a.artifact_sha256<>r.artifact_sha256 OR a.profile_id<>r.profile_id OR a.adapter_version<>r.adapter_version",
      "SELECT 1 FROM receipt_preservation_anchor WHERE length(anchor_id)<>64 OR anchor_id GLOB '*[^0-9a-f]*' OR length(source_subject_id)<>64 OR source_subject_id GLOB '*[^0-9a-f]*' OR length(artifact_sha256)<>64 OR artifact_sha256 GLOB '*[^0-9a-f]*'",
      "SELECT 1 FROM receipt_preservation_payload WHERE length(payload_id)<>64 OR payload_id GLOB '*[^0-9a-f]*' OR length(anchor_id)<>64 OR anchor_id GLOB '*[^0-9a-f]*' OR length(source_subject_id)<>64 OR source_subject_id GLOB '*[^0-9a-f]*' OR length(provenance_id)<>64 OR provenance_id GLOB '*[^0-9a-f]*'",
      "SELECT 1 FROM receipt_preservation_membership m LEFT JOIN receipt_preservation_anchor a ON a.idempotency_key=m.idempotency_key AND a.anchor_id=m.anchor_id AND a.source_subject_id=m.anchor_subject_id AND a.subject_kind=m.anchor_subject_kind LEFT JOIN receipt_preservation_payload p ON p.idempotency_key=m.idempotency_key AND p.anchor_id=m.anchor_id AND p.payload_id=m.payload_id AND p.source_subject_id=m.source_subject_id WHERE a.anchor_id IS NULL OR (m.subject_kind IN ('table','record') AND (m.payload_id IS NOT NULL OR m.source_subject_id<>m.anchor_subject_id OR m.subject_kind<>m.anchor_subject_kind)) OR (m.subject_kind='field' AND (m.payload_id IS NULL OR p.payload_id IS NULL OR m.source_subject_id=m.anchor_subject_id OR m.anchor_subject_kind<>'record'))",
      "SELECT 1 FROM receipt_preservation_payload p LEFT JOIN receipt_preservation_anchor a ON a.idempotency_key=p.idempotency_key AND a.anchor_id=p.anchor_id WHERE a.anchor_id IS NULL",
      "SELECT 1 FROM receipt_preservation_payload x JOIN receipt_preservation_anchor a ON a.idempotency_key=x.idempotency_key AND a.anchor_id=x.anchor_id JOIN provenance_reference p ON p.provenance_id=x.provenance_id WHERE x.provenance_id<>x.source_subject_id OR a.subject_kind<>'record' OR p.artifact_sha256<>a.artifact_sha256 OR p.profile_id<>a.profile_id OR p.adapter_version<>a.adapter_version OR p.source_table<>a.source_table OR p.source_record_key<>a.source_record_key",
      "SELECT 1 FROM receipt_sidecar r JOIN import_receipt i ON i.idempotency_key=r.idempotency_key JOIN sidecar_reference s ON s.sidecar_id=r.sidecar_id AND s.event_id=r.event_id AND s.provenance_id=r.provenance_id JOIN provenance_reference p ON p.provenance_id=s.provenance_id WHERE s.provenance_id<>s.sidecar_id OR p.artifact_sha256<>i.artifact_sha256 OR p.profile_id<>i.profile_id OR p.adapter_version<>i.adapter_version",
      "SELECT a.anchor_id FROM receipt_preservation_anchor a LEFT JOIN receipt_preservation_membership m ON m.idempotency_key=a.idempotency_key AND m.anchor_id=a.anchor_id AND m.source_subject_id=a.source_subject_id AND m.payload_id IS NULL GROUP BY a.anchor_id HAVING count(m.idempotency_key)<>1",
      "SELECT p.payload_id FROM receipt_preservation_payload p LEFT JOIN receipt_preservation_membership m ON m.idempotency_key=p.idempotency_key AND m.payload_id=p.payload_id AND m.source_subject_id=p.source_subject_id GROUP BY p.payload_id HAVING count(m.idempotency_key)<>1",
      "SELECT 1 FROM import_receipt r WHERE r.event_count=0 AND NOT EXISTS (SELECT 1 FROM receipt_preservation_membership m WHERE m.idempotency_key=r.idempotency_key)",
      "SELECT 1 FROM provenance_reference p WHERE NOT EXISTS (SELECT 1 FROM event_source_binding b WHERE b.provenance_id=p.provenance_id) AND NOT EXISTS (SELECT 1 FROM sidecar_reference s WHERE s.provenance_id=p.provenance_id) AND NOT EXISTS (SELECT 1 FROM receipt_preservation_payload x WHERE x.provenance_id=p.provenance_id)",
    ]
    for query in invalidQueries where try !rows(database, query, { _ in () }).isEmpty {
      throw HealthError.invalid
    }
    try validateReceiptDigests(database, trustKey: trustKey)
  }

  /// Recomputes persisted receipt anchors from the canonical graph. MMImport may validate a
  /// requested receipt additionally, but this is the authority for every stored receipt.
  private static func validateReceiptDigests(_ database: OpaquePointer, trustKey: Data?) throws {
    let schemaVersion = try require(
      rows(database, "SELECT value FROM ledger_meta WHERE key='schema_version'", { $0.text(0) })
        .first)
    for receipt in try rows(
      database,
      "SELECT idempotency_key, staging_digest, artifact_sha256, profile_id, adapter_version, reconciliation_hash, event_set_hash, event_count, schema_version FROM import_receipt ORDER BY idempotency_key",
      { $0 }
    ) {
      guard receipt.textColumns([0, 1, 2, 3, 4, 5, 6]), receipt.integerColumns([7, 8])
      else { throw HealthError.invalid }
      let receiptID = receipt.text(0)
      guard CanonicalIdentifier.isValid(receiptID) else { throw HealthError.invalid }
      let identity = try receiptIdentity(database, receipt: receiptID)
      // This must run before event replay: a preserved-subject-only v19 receipt has no event
      // row through which the adapter version would otherwise be checked.
      if MoneyManagerV19Semantics.admittedProfileIDs.contains(identity.profileID),
        identity.adapterVersion != MoneyManagerV19Semantics.adapterVersion
      {
        throw HealthError.invalid
      }
      try validateAdmittedV19EffectOrdinals(database, receipt: receiptID, identity: identity)
      let eventSetHash = try canonicalEventSetHash(database, receipt: receiptID)
      let envelope = try receiptIntegrityEnvelope(database, receipt: receiptID)
      let preservationHash = try canonicalPreservationSetHash(database, receipt: receiptID)
      if MoneyManagerV19Semantics.admittedProfileIDs.contains(identity.profileID) {
        guard
          let generation = MoneyManagerV19Semantics.authenticatedReceiptGeneration(
            storedIntegrityHash: receipt.text(5), envelope: envelope,
            eventSetHash: eventSetHash, preservationHash: preservationHash)
        else { throw HealthError.invalid }
        let declaredGeneration = try declaredV19ReceiptGeneration(
          database, receipt: receiptID)
        // A non-empty v19 receipt must carry an immutable generation declaration.  Zero-event
        // receipts have no transaction revision on which to store that declaration, so they may
        // only use the current digest and can never be downgraded to the legacy digest.
        let eventCount = receipt.int(7)
        if let declaredGeneration {
          guard declaredGeneration == generation else { throw HealthError.invalid }
        } else {
          guard eventCount == 0, generation == .current else { throw HealthError.invalid }
        }
        // v11 is the first schema that writes the explicit current-generation marker. A
        // mutable legacy marker must never downgrade an already-migrated v11 receipt. v10 is
        // read-only migration input and may retain its historical legacy marker until upgrade.
        if schemaVersion == String(CanonicalLedgerSchema.version) {
          guard generation == .current else { throw HealthError.invalid }
        }
        try validateAdmittedV19OpaqueCompleteness(
          database, receipt: receiptID, identity: identity, generation: generation,
          requireCurrentMarkers: schemaVersion == String(CanonicalLedgerSchema.version))
        if schemaVersion == String(CanonicalLedgerSchema.version) {
          try validateReceiptTrustAnchor(
            database, receipt: receiptID, integrityHash: receipt.text(5), trustKey: trustKey)
        }
      } else {
        guard
          receipt.text(5)
            == MoneyManagerV19Semantics.receiptIntegrityHash(
              envelope: envelope, eventSetHash: eventSetHash,
              preservationHash: preservationHash, generation: .legacy)
        else { throw HealthError.invalid }
      }
      guard receipt.text(6) == eventSetHash else { throw HealthError.invalid }
    }
  }

  private static func validateReceiptTrustAnchor(
    _ database: OpaquePointer, receipt: String, integrityHash: String, trustKey: Data?
  ) throws {
    guard let trustKey else { throw HealthError.invalid }
    let anchors = try rows(
      database,
      "SELECT algorithm, signature FROM ledger_receipt_trust_anchor WHERE idempotency_key='\(receipt)'",
      { $0 })
    guard anchors.count == 1, anchors[0].text(0) == LedgerReceiptTrust.algorithm,
      LedgerReceiptTrust.verifies(
        key: trustKey, signature: anchors[0].text(1), receiptID: receipt,
        integrityHash: integrityHash)
    else { throw HealthError.invalid }
  }

  private static func validateAdmittedV19EffectOrdinals(
    _ database: OpaquePointer, receipt: String, identity: ReceiptIdentity
  ) throws {
    guard MoneyManagerV19Semantics.admittedProfileIDs.contains(identity.profileID) else { return }
    let eventsBySource = Dictionary(
      grouping: try rows(
        database,
        "SELECT e.source_record_id, e.event_id FROM receipt_event r JOIN economic_event e ON e.event_id=r.event_id WHERE r.idempotency_key='\(receipt)' ORDER BY e.source_record_id, e.event_id",
        { ($0.text(0), $0.text(1)) }), by: \.0)
    for (sourceRecordID, rows) in eventsBySource {
      guard rows.count == 1,
        rows[0].1 == (try StableCanonicalID.event(sourceRecordID: sourceRecordID, effectOrdinal: 0))
      else { throw HealthError.invalid }
    }
  }

  /// Current v19 receipts authenticate their generation in the receipt digest. Legacy behavior is
  /// selected only by an authenticated legacy digest, never by a missing source-literal marker.
  private static func validateAdmittedV19OpaqueCompleteness(
    _ database: OpaquePointer, receipt: String, identity: ReceiptIdentity,
    generation: MoneyManagerV19Semantics.ReceiptGeneration, requireCurrentMarkers: Bool
  ) throws {
    guard MoneyManagerV19Semantics.admittedProfileIDs.contains(identity.profileID) else { return }
    let eventSourceRecordIDs = Set(
      try rows(
        database,
        "SELECT e.source_record_id FROM receipt_event r JOIN economic_event e ON e.event_id=r.event_id WHERE r.idempotency_key='\(receipt)'",
        { $0.text(0) }))
    let preservedRecordIDs = Set(
      try rows(
        database,
        "SELECT source_subject_id FROM receipt_preservation_anchor WHERE idempotency_key='\(receipt)' AND subject_kind='record'",
        { $0.text(0) }))
    for field in try rows(
      database,
      "SELECT provenance_id, source_table, source_record_key FROM provenance_reference WHERE artifact_sha256='\(identity.artifactSHA256)' AND profile_id='\(identity.profileID)' AND adapter_version='\(identity.adapterVersion)'",
      { $0 })
    {
      let sourceRecordID = CanonicalStagingID.record(
        stagingID: receipt, table: field.text(1), recordKey: field.text(2))
      guard
        eventSourceRecordIDs.contains(sourceRecordID) || preservedRecordIDs.contains(sourceRecordID)
      else { continue }
      let represented = try !rows(
        database,
        "SELECT 1 FROM sidecar_reference WHERE provenance_id='\(field.text(0))' UNION ALL SELECT 1 FROM receipt_preservation_payload WHERE idempotency_key='\(receipt)' AND provenance_id='\(field.text(0))' LIMIT 1",
        { _ in true }
      ).isEmpty
      guard represented else { throw HealthError.invalid }
    }
    let events = try rows(
      database,
      "SELECT e.event_id, e.account_id, e.event_kind, e.amount_literal, e.currency_unit, e.instant_milliseconds, e.local_year, e.local_month, e.local_day, e.local_hour, e.local_minute, e.local_second, e.local_millisecond, e.timezone_kind, e.timezone_value, e.temporal_precision, e.resolved_offset_seconds, e.source_record_id, e.provenance_id FROM receipt_event r JOIN economic_event e ON e.event_id=r.event_id WHERE r.idempotency_key='\(receipt)' ORDER BY e.event_id",
      { $0 })
    let hasTransferTable = try transferTableExists(database)
    for event in events {
      let eventID = event.text(0)
      // A paired transfer leg's commitments live on its transfer's revision, under field names
      // that name the leg; every other event uses its own transaction and the plain names.
      guard let eventKind = CanonicalEventKind(rawValue: event.text(2)) else {
        throw HealthError.invalid
      }
      let transactionID =
        try hasTransferTable
        ? rows(
          database,
          "SELECT transfer_id FROM economic_event_transfer WHERE debit_event_id='\(eventID)' OR credit_event_id='\(eventID)'",
          { $0.text(0) }
        ).first ?? eventID
        : eventID
      func field(_ name: String) -> String {
        MoneyManagerV19Semantics.commitmentField(name, kind: eventKind)
      }
      let sourceRecordID = event.text(17)
      let commitments = try rows(
        database,
        "SELECT l.literal FROM ledger_transaction_source_literal l JOIN ledger_transaction_revision v ON v.revision_id=l.revision_id WHERE v.transaction_id='\(transactionID)' AND l.field='\(field(MoneyManagerV19Semantics.temporalCommitmentField))'",
        { $0.text(0) })
      guard commitments.count <= 1 else { throw HealthError.invalid }
      if generation == .current, commitments.count > 1 { throw HealthError.invalid }
      let temporalAnchors = try rows(
        database,
        "SELECT l.literal FROM ledger_transaction_source_literal l JOIN ledger_transaction_revision v ON v.revision_id=l.revision_id WHERE v.transaction_id='\(transactionID)' AND l.field='\(field(MoneyManagerV19Semantics.temporalAnchorField))'",
        { $0.text(0) })
      guard temporalAnchors.count <= 1 else { throw HealthError.invalid }
      if generation == .current {
        // Every admitted current-generation event must retain both sides of the temporal proof.
        // A missing pair would let a mutable graph keep its receipt hash while losing the source
        // timezone/instant evidence that made the import admissible.
        guard commitments.count == 1, temporalAnchors.count == 1,
          temporalAnchors[0] == commitments[0]
        else { throw HealthError.invalid }
      }
      if generation == .legacy {
        // Legacy v19 data is only admissible as pre-v11 migration input. It never carries the
        // current temporal proof graph, and a replacement legacy marker cannot downgrade it.
        guard commitments.isEmpty, temporalAnchors.isEmpty else { throw HealthError.invalid }
      }
      if commitments.count == 1 {
        guard temporalAnchors.count == 1, temporalAnchors[0] == commitments[0]
        else { throw HealthError.invalid }
      } else {
        guard temporalAnchors.isEmpty else { throw HealthError.invalid }
      }
      let generationDeclarations = try rows(
        database,
        "SELECT l.literal FROM ledger_transaction_source_literal l JOIN ledger_transaction_revision v ON v.revision_id=l.revision_id WHERE v.transaction_id='\(transactionID)' AND l.field='\(field(MoneyManagerV19Semantics.receiptGenerationField))'",
        { $0.text(0) })
      guard generationDeclarations.count == 1,
        generationDeclarations[0]
          == (generation == .current
            ? MoneyManagerV19Semantics.currentReceiptGenerationLiteral
            : MoneyManagerV19Semantics.legacyReceiptGenerationLiteral)
      else { throw HealthError.invalid }
      if let commitment = commitments.first {
        guard commitment == MoneyManagerV19Semantics.temporalCommitment(try sourceTemporal(event))
        else { throw HealthError.invalid }
        let committedAnchors = try rows(
          database,
          "SELECT 1 FROM receipt_preservation_anchor a JOIN receipt_preservation_membership m ON m.idempotency_key=a.idempotency_key AND m.anchor_id=a.anchor_id AND m.source_subject_id=a.source_subject_id AND m.subject_kind='record' AND m.payload_id IS NULL WHERE a.idempotency_key='\(receipt)' AND a.subject_kind='record' AND a.source_subject_id='\(sourceRecordID)'",
          { _ in true })
        guard committedAnchors.count == 1 else { throw HealthError.invalid }
      }
      let hasAnchor = try !rows(
        database,
        "SELECT 1 FROM receipt_preservation_anchor WHERE idempotency_key='\(receipt)' AND subject_kind='record' AND source_subject_id='\(sourceRecordID)' LIMIT 1",
        { _ in true }
      ).isEmpty
      guard hasAnchor || commitments.isEmpty else { throw HealthError.invalid }
      let sourceSubjectSetMarkers = try rows(
        database,
        "SELECT l.literal FROM ledger_transaction_source_literal l JOIN ledger_transaction_revision v ON v.revision_id=l.revision_id WHERE v.transaction_id='\(transactionID)' AND l.field='\(field(MoneyManagerV19Semantics.sourceSubjectSetField))'",
        { $0.text(0) })
      let sourceTimeZoneMarkers = try rows(
        database,
        "SELECT l.literal FROM ledger_transaction_source_literal l JOIN ledger_transaction_revision v ON v.revision_id=l.revision_id WHERE v.transaction_id='\(transactionID)' AND l.field='\(field(MoneyManagerV19Semantics.sourceTimeZoneField))'",
        { $0.text(0) })
      if generation == .current && requireCurrentMarkers {
        let fieldIDs = try rows(
          database,
          "SELECT sidecar_id FROM sidecar_reference WHERE event_id='\(eventID)' ORDER BY sidecar_id",
          { $0.text(0) })
        let expectedSubjectSet = MoneyManagerV19Semantics.sourceSubjectSetCommitment(
          sourceRecordID: sourceRecordID, fieldIDs: fieldIDs)
        let expectedTimeZone = MoneyManagerV19Semantics.sourceTimeZoneLiteral(
          try sourceTemporal(event).timeZone)
        guard sourceSubjectSetMarkers.count == 1, sourceSubjectSetMarkers[0] == expectedSubjectSet,
          sourceTimeZoneMarkers.count == 1, sourceTimeZoneMarkers[0] == expectedTimeZone
        else { throw HealthError.invalid }
      } else if generation == .legacy {
        guard sourceSubjectSetMarkers.isEmpty, sourceTimeZoneMarkers.isEmpty else {
          throw HealthError.invalid
        }
      }
      if !hasAnchor { continue }
      let missingPreservation = try rows(
        database,
        "SELECT 1 FROM sidecar_reference s JOIN receipt_event r ON r.event_id=s.event_id LEFT JOIN event_source_binding b ON b.event_id=s.event_id AND b.provenance_id=s.provenance_id LEFT JOIN receipt_preservation_payload p ON p.idempotency_key=r.idempotency_key AND p.source_subject_id=s.provenance_id WHERE r.idempotency_key='\(receipt)' AND s.event_id IN (SELECT event_id FROM economic_event WHERE source_record_id='\(sourceRecordID)') AND b.provenance_id IS NULL AND (p.payload_id IS NULL OR p.format_version<>s.format_version OR p.declared_type IS NOT s.declared_type OR p.storage_class<>s.storage_class OR p.payload<>s.payload) LIMIT 1",
        { _ in true })
      let missingSidecar = try rows(
        database,
        "SELECT 1 FROM receipt_preservation_payload p JOIN receipt_preservation_anchor a ON a.idempotency_key=p.idempotency_key AND a.anchor_id=p.anchor_id LEFT JOIN sidecar_reference s ON s.provenance_id=p.provenance_id LEFT JOIN receipt_event r ON r.idempotency_key=p.idempotency_key AND r.event_id=s.event_id LEFT JOIN event_source_binding b ON b.event_id=s.event_id AND b.provenance_id=s.provenance_id WHERE p.idempotency_key='\(receipt)' AND a.source_subject_id='\(sourceRecordID)' AND s.sidecar_id IS NULL AND b.provenance_id IS NULL LIMIT 1",
        { _ in true })
      guard missingPreservation.isEmpty, missingSidecar.isEmpty else { throw HealthError.invalid }
    }
  }

  private static func transferTableExists(_ database: OpaquePointer) throws -> Bool {
    try !rows(
      database,
      "SELECT 1 FROM sqlite_master WHERE type='table' AND name='economic_event_transfer'",
      { _ in true }
    ).isEmpty
  }

  private static func declaredV19ReceiptGeneration(
    _ database: OpaquePointer, receipt: String
  ) throws -> MoneyManagerV19Semantics.ReceiptGeneration? {
    // Ledgers older than v12 have no transfer table and no paired legs.
    let transactionOfEvent =
      try transferTableExists(database)
      ? "COALESCE((SELECT t.transfer_id FROM economic_event_transfer t WHERE t.debit_event_id=r.event_id OR t.credit_event_id=r.event_id), r.event_id)"
      : "r.event_id"
    let values = try rows(
      database,
      "SELECT DISTINCT l.literal FROM ledger_transaction_source_literal l JOIN ledger_transaction_revision v ON v.revision_id=l.revision_id JOIN receipt_event r ON v.transaction_id=\(transactionOfEvent) WHERE r.idempotency_key='\(receipt)' AND l.field IN ('\(MoneyManagerV19Semantics.receiptGenerationField)', '\(MoneyManagerV19Semantics.receiptGenerationField).debit', '\(MoneyManagerV19Semantics.receiptGenerationField).credit')",
      { $0.text(0) })
    guard values.count <= 1 else { throw HealthError.invalid }
    switch values.first {
    case MoneyManagerV19Semantics.currentReceiptGenerationLiteral: return .current
    case MoneyManagerV19Semantics.legacyReceiptGenerationLiteral: return .legacy
    case nil: return nil
    default: throw HealthError.invalid
    }
  }

  private static func receiptIntegrityEnvelope(_ database: OpaquePointer, receipt: String) throws
    -> [String]
  {
    try require(
      rows(
        database,
        "SELECT idempotency_key, staging_digest, artifact_sha256, profile_id, adapter_version, event_set_hash, event_count, schema_version FROM import_receipt WHERE idempotency_key='\(receipt)'",
        { row in
          guard row.textColumns([0, 1, 2, 3, 4, 5]), row.integerColumns([6, 7])
          else { throw HealthError.invalid }
          return [
            row.text(0), row.text(1), row.text(2), row.text(3), row.text(4), row.text(5),
            String(row.int64(6)), String(row.int64(7)),
          ]
        }
      ).first)
  }

  private static func canonicalPreservationSetHash(_ database: OpaquePointer, receipt: String)
    throws -> String
  {
    let identity = try receiptIdentity(database, receipt: receipt)
    var components = ["ledger-atlas/receipt-owned-preservation-set/v4"]
    for row in try rows(
      database,
      "SELECT idempotency_key, source_subject_id, subject_kind, anchor_id, anchor_subject_id, anchor_subject_kind, payload_id FROM receipt_preservation_membership WHERE idempotency_key='\(receipt)' ORDER BY source_subject_id",
      { $0 }
    ) {
      guard row.textColumns([0, 1, 2, 3, 4, 5]), row.nullOrText(6) else {
        throw HealthError.invalid
      }
      components.append(contentsOf: [
        row.text(0), row.text(1), row.text(2), row.text(3), row.text(4), row.text(5),
      ])
      components.append(contentsOf: CanonicalReceiptDigest.optionalComponents(row.optionalText(6)))
    }
    for row in try rows(
      database,
      "SELECT a.anchor_id, a.idempotency_key, a.source_subject_id, a.subject_kind, a.artifact_sha256, a.profile_id, a.adapter_version, a.container_member, a.source_table, a.source_record_key FROM receipt_preservation_membership m JOIN receipt_preservation_anchor a ON a.idempotency_key=m.idempotency_key AND a.anchor_id=m.anchor_id WHERE m.idempotency_key='\(receipt)' AND m.subject_kind IN ('table','record') ORDER BY a.anchor_id",
      { $0 }
    ) {
      guard row.textColumns([0, 1, 2, 3, 4, 5, 6, 8]), row.nullOrText(7), row.nullOrText(9)
      else { throw HealthError.invalid }
      let kind = try enumValue(CanonicalPreservationSubjectKind.self, row.text(3))
      let sourceSubjectID = row.text(2)
      let expectedSubjectID =
        kind == .table
        ? CanonicalStagingID.table(stagingID: receipt, table: row.text(8))
        : CanonicalStagingID.record(
          stagingID: receipt, table: row.text(8), recordKey: row.optionalText(9) ?? "")
      guard sourceSubjectID == expectedSubjectID else { throw HealthError.invalid }
      _ = try CanonicalReceiptOwnedAnchor(
        anchorID: row.text(0), receiptID: row.text(1), sourceSubjectID: sourceSubjectID,
        subjectKind: kind, artifactSHA256: row.text(4), profileID: row.text(5),
        adapterVersion: row.text(6), containerMember: row.optionalText(7),
        sourceTable: row.text(8), sourceRecordKey: row.optionalText(9))
      guard row.text(4) == identity.artifactSHA256, row.text(5) == identity.profileID,
        row.text(6) == identity.adapterVersion
      else { throw HealthError.invalid }
      components.append(contentsOf: [
        row.text(0), row.text(1), row.text(2), row.text(3), row.text(4), row.text(5), row.text(6),
      ])
      components.append(contentsOf: CanonicalReceiptDigest.optionalComponents(row.optionalText(7)))
      components.append(row.text(8))
      components.append(contentsOf: CanonicalReceiptDigest.optionalComponents(row.optionalText(9)))
    }
    for row in try rows(
      database,
      "SELECT x.payload_id, x.idempotency_key, x.anchor_id, x.source_subject_id, x.provenance_id, x.format_version, x.declared_type, x.storage_class, x.payload, p.artifact_sha256, p.profile_id, p.adapter_version, p.container_member, p.source_table, p.source_record_key, p.source_column_ordinal, p.source_column_name FROM receipt_preservation_membership m JOIN receipt_preservation_payload x ON x.idempotency_key=m.idempotency_key AND x.payload_id=m.payload_id JOIN provenance_reference p ON p.provenance_id=x.provenance_id WHERE m.idempotency_key='\(receipt)' AND m.subject_kind='field' ORDER BY x.payload_id",
      { $0 }
    ) {
      guard row.textColumns([0, 1, 2, 3, 4, 7, 9, 10, 11, 13, 14]),
        row.integerColumns([5]), row.blobColumns([8]), row.nullOrText(6), row.nullOrText(12),
        row.nullOrInteger(15), row.nullOrText(16)
      else { throw HealthError.invalid }
      let provenance = try provenance(
        id: row.text(4), artifactSHA256: row.text(9), profileID: row.text(10),
        adapterVersion: row.text(11), containerMember: row.optionalText(12),
        table: row.text(13), recordKey: row.text(14), columnOrdinal: row.optionalInt(15),
        columnName: row.optionalText(16), receipt: receipt, identity: identity)
      guard row.text(3) == provenance.deterministicID else { throw HealthError.invalid }
      _ = try CanonicalReceiptOwnedPayload(
        payloadID: row.text(0), receiptID: row.text(1), anchorID: row.text(2),
        sourceSubjectID: row.text(3), formatVersion: row.int(5),
        declaredType: row.optionalText(6),
        storageClass: enumValue(CanonicalFieldStorageClass.self, row.text(7)),
        payload: row.blob(8), provenance: provenance)
      components.append(contentsOf: [
        row.text(0), row.text(1), row.text(2), row.text(3), String(row.int64(5)),
      ])
      components.append(contentsOf: CanonicalReceiptDigest.optionalComponents(row.optionalText(6)))
      components.append(contentsOf: [
        row.text(7), CanonicalReceiptDigest.sha256(row.blob(8)), row.text(9), row.text(10),
        row.text(11),
      ])
      components.append(contentsOf: CanonicalReceiptDigest.optionalComponents(row.optionalText(12)))
      components.append(contentsOf: [row.text(13), row.text(14)])
      components.append(
        contentsOf: CanonicalReceiptDigest.optionalComponents(row.optionalInt(15).map(String.init)))
      components.append(contentsOf: CanonicalReceiptDigest.optionalComponents(row.optionalText(16)))
      components.append(row.text(4))
    }
    return CanonicalReceiptDigest.hash(components)
  }

  private static func canonicalEventSetHash(_ database: OpaquePointer, receipt: String) throws
    -> String
  {
    let identity = try receiptIdentity(database, receipt: receipt)
    var components = [CanonicalReceiptDigest.eventSetPrefix]
    for row in try rows(
      database,
      "SELECT e.event_id, e.account_id, e.event_kind, e.amount_literal, e.currency_unit, e.instant_milliseconds, e.local_year, e.local_month, e.local_day, e.local_hour, e.local_minute, e.local_second, e.local_millisecond, e.timezone_kind, e.timezone_value, e.temporal_precision, e.resolved_offset_seconds, e.source_record_id, e.provenance_id FROM receipt_event r JOIN economic_event e ON e.event_id=r.event_id WHERE r.idempotency_key='\(receipt)' ORDER BY e.event_id",
      { $0 }
    ) {
      let eventID = row.text(0)
      guard CanonicalIdentifier.isValid(eventID),
        row.textColumns([0, 1, 2, 3, 4, 13, 14, 15, 17, 18]),
        row.integerColumns(Array(5...12) + [16])
      else { throw HealthError.invalid }
      components.append(
        contentsOf: [eventID, row.text(1), row.text(2), row.text(3), row.text(4)]
          + (5...12).map { String(row.int64(Int32($0))) } + [
            row.text(13), row.text(14), row.text(15), String(row.int64(16)), row.text(17),
            row.text(18),
          ])
      var bindings: [CanonicalEventSourceBinding] = []
      for binding in try rows(
        database,
        "SELECT b.semantic, b.provenance_id, b.declared_type, b.storage_class, p.artifact_sha256, p.profile_id, p.adapter_version, p.container_member, p.source_table, p.source_record_key, p.source_column_ordinal, p.source_column_name FROM event_source_binding b JOIN provenance_reference p ON p.provenance_id=b.provenance_id WHERE b.event_id='\(eventID)' ORDER BY b.semantic",
        { $0 }
      ) {
        guard binding.textColumns([0, 1, 3, 4, 5, 6, 8, 9]), binding.nullOrText(2),
          binding.nullOrText(7), binding.nullOrInteger(10), binding.nullOrText(11)
        else {
          throw HealthError.invalid
        }
        let bindingProvenance = try provenance(
          id: binding.text(1), artifactSHA256: binding.text(4), profileID: binding.text(5),
          adapterVersion: binding.text(6), containerMember: binding.optionalText(7),
          table: binding.text(8), recordKey: binding.text(9),
          columnOrdinal: binding.optionalInt(10), columnName: binding.optionalText(11),
          receipt: receipt, identity: identity)
        bindings.append(
          try CanonicalEventSourceBinding(
            semantic: enumValue(CanonicalEventSourceSemantic.self, binding.text(0)),
            provenance: bindingProvenance, declaredType: binding.optionalText(2),
            storageClass: enumValue(CanonicalFieldStorageClass.self, binding.text(3))))
        components.append(contentsOf: [binding.text(0), binding.text(1)])
        components.append(
          contentsOf: CanonicalReceiptDigest.optionalComponents(binding.optionalText(2)))
        components.append(binding.text(3))
      }
      var sidecarReferences: [CanonicalSidecarReference] = []
      var retainedSidecars: [MoneyManagerV19Semantics.RetainedSidecar] = []
      for sidecar in try rows(
        database,
        "SELECT s.sidecar_id, s.provenance_id, s.format_version, s.declared_type, s.storage_class, s.payload, p.artifact_sha256, p.profile_id, p.adapter_version, p.container_member, p.source_table, p.source_record_key, p.source_column_ordinal, p.source_column_name FROM sidecar_reference s JOIN provenance_reference p ON p.provenance_id=s.provenance_id WHERE s.event_id='\(eventID)' ORDER BY s.sidecar_id",
        { $0 }
      ) {
        guard sidecar.textColumns([0, 1, 4, 6, 7, 8, 10, 11]),
          sidecar.integerColumns([2]), sidecar.blobColumns([5]), sidecar.nullOrText(3),
          sidecar.nullOrText(9), sidecar.nullOrInteger(12), sidecar.nullOrText(13)
        else { throw HealthError.invalid }
        let sidecarProvenance = try provenance(
          id: sidecar.text(1), artifactSHA256: sidecar.text(6), profileID: sidecar.text(7),
          adapterVersion: sidecar.text(8), containerMember: sidecar.optionalText(9),
          table: sidecar.text(10), recordKey: sidecar.text(11),
          columnOrdinal: sidecar.optionalInt(12), columnName: sidecar.optionalText(13),
          receipt: receipt, identity: identity)
        guard
          row.text(17)
            == CanonicalStagingID.record(
              stagingID: receipt, table: sidecarProvenance.locator.table,
              recordKey: sidecarProvenance.locator.recordKey)
        else { throw HealthError.invalid }
        _ = try CanonicalPersistedSidecar(
          sidecarID: sidecar.text(0), eventID: eventID, formatVersion: sidecar.int(2),
          declaredType: sidecar.optionalText(3),
          storageClass: enumValue(CanonicalFieldStorageClass.self, sidecar.text(4)),
          payload: sidecar.blob(5), provenance: sidecarProvenance)
        sidecarReferences.append(
          try CanonicalSidecarReference(
            sidecarID: sidecar.text(0), provenanceID: sidecar.text(1)))
        retainedSidecars.append(
          .init(
            locator: sidecarProvenance.locator,
            storageClass: try enumValue(CanonicalFieldStorageClass.self, sidecar.text(4)),
            payload: sidecar.blob(5)))
        components.append(contentsOf: [sidecar.text(0), sidecar.text(1), String(sidecar.int64(2))])
        components.append(
          contentsOf: CanonicalReceiptDigest.optionalComponents(sidecar.optionalText(3)))
        components.append(contentsOf: [
          sidecar.text(4), CanonicalReceiptDigest.sha256(sidecar.blob(5)), sidecar.text(6),
          sidecar.text(7), sidecar.text(8),
        ])
        components.append(
          contentsOf: CanonicalReceiptDigest.optionalComponents(sidecar.optionalText(9)))
        components.append(contentsOf: [sidecar.text(10), sidecar.text(11)])
        components.append(
          contentsOf: CanonicalReceiptDigest.optionalComponents(
            sidecar.optionalInt(12).map(String.init)))
        components.append(
          contentsOf: CanonicalReceiptDigest.optionalComponents(sidecar.optionalText(13)))
      }
      guard let amountBinding = bindings.first(where: { $0.semantic == .amount }),
        amountBinding.provenance.deterministicID == row.text(18),
        row.text(17)
          == CanonicalStagingID.record(
            stagingID: receipt, table: amountBinding.provenance.locator.table,
            recordKey: amountBinding.provenance.locator.recordKey)
      else { throw HealthError.invalid }
      let event = try CanonicalEconomicEvent(
        eventID: eventID, accountID: row.text(1),
        kind: enumValue(CanonicalEventKind.self, row.text(2)),
        amount: CurrencyAmount(unitCode: row.text(4), amount: ExactDecimal(row.text(3))),
        occurredAt: sourceTemporal(row), sourceRecordID: row.text(17),
        amountProvenance: amountBinding.provenance, sourceBindings: bindings,
        sidecarReferences: sidecarReferences)
      let retained = try retainedSemanticFields(
        database, eventID: eventID, receipt: receipt, bindings: bindings)
      try validateGenericRetainedSemantics(event: event, fields: retained)
      guard
        MoneyManagerV19Semantics.validateReplay(
          profileID: identity.profileID, adapterVersion: identity.adapterVersion,
          event: event, fields: retained, sidecars: retainedSidecars,
          temporalCommitment: MoneyManagerV19Semantics.temporalCommitment(event.occurredAt))
          != .invalid
      else { throw HealthError.invalid }
    }
    return CanonicalReceiptDigest.hash(components)
  }

  /// Event sidecars and receipt-owned payloads are the only retained source bytes health may
  /// replay. When both retain a binding, they must agree exactly.
  private static func retainedSemanticFields(
    _ database: OpaquePointer, eventID: String, receipt: String,
    bindings: [CanonicalEventSourceBinding]
  ) throws -> [MoneyManagerV19Semantics.RetainedField] {
    var result: [MoneyManagerV19Semantics.RetainedField] = []
    for binding in bindings {
      let sidecars = try rows(
        database,
        "SELECT declared_type, storage_class, payload FROM sidecar_reference WHERE event_id='\(eventID)' AND provenance_id='\(binding.provenance.deterministicID)'",
        { $0 })
      guard sidecars.count <= 1 else { throw HealthError.invalid }
      let payloads = try rows(
        database,
        "SELECT declared_type, storage_class, payload FROM receipt_preservation_payload WHERE idempotency_key='\(receipt)' AND provenance_id='\(binding.provenance.deterministicID)'",
        { $0 })
      guard payloads.count <= 1 else { throw HealthError.invalid }
      guard let source = sidecars.first ?? payloads.first else { continue }
      guard source.nullOrText(0), source.textColumns([1]), source.blobColumns([2]),
        source.optionalText(0) == binding.declaredType,
        source.text(1) == binding.storageClass.rawValue
      else { throw HealthError.invalid }
      if let sidecar = sidecars.first, let payload = payloads.first,
        sidecar.optionalText(0) != payload.optionalText(0) || sidecar.text(1) != payload.text(1)
          || sidecar.blob(2) != payload.blob(2)
      {
        throw HealthError.invalid
      }
      result.append(
        .init(
          semantic: binding.semantic, locator: binding.provenance.locator,
          storageClass: binding.storageClass, payload: source.blob(2)))
    }
    return result
  }

  private static func validateGenericRetainedSemantics(
    event: CanonicalEconomicEvent, fields: [MoneyManagerV19Semantics.RetainedField]
  ) throws {
    for field in fields {
      let literal = MoneyManagerV19Semantics.mappingLiteral(
        storageClass: field.storageClass, payload: field.payload)
      switch field.semantic {
      case .amount:
        guard let literal, literal == event.amount.amount.rawLiteral else {
          throw HealthError.invalid
        }
      case .currency:
        guard let literal, literal == event.amount.unitCode else { throw HealthError.invalid }
      case .account:
        // Account source values need the profile selector, so the adapter proof owns them.
        guard literal != nil else { throw HealthError.invalid }
      case .occurredAt, .kind:
        break
      }
    }
  }

  private struct ReceiptIdentity {
    let artifactSHA256: String
    let profileID: String
    let adapterVersion: String
  }

  private static func receiptIdentity(_ database: OpaquePointer, receipt: String) throws
    -> ReceiptIdentity
  {
    let row = try require(
      rows(
        database,
        "SELECT artifact_sha256, profile_id, adapter_version FROM import_receipt WHERE idempotency_key='\(receipt)'",
        { $0 }
      ).first)
    guard row.textColumns([0, 1, 2]), CanonicalIdentifier.isValid(row.text(0)),
      !row.text(1).isEmpty, row.text(1).utf8.count <= 256,
      !row.text(2).isEmpty, row.text(2).utf8.count <= 256,
      receipt
        == CanonicalStagingID.stage(
          artifactSHA256: row.text(0), profileID: row.text(1), adapterVersion: row.text(2))
    else { throw HealthError.invalid }
    return ReceiptIdentity(
      artifactSHA256: row.text(0), profileID: row.text(1), adapterVersion: row.text(2))
  }

  private static func provenance(
    id: String, artifactSHA256: String, profileID: String, adapterVersion: String,
    containerMember: String?, table: String, recordKey: String, columnOrdinal: Int?,
    columnName: String?, receipt: String, identity: ReceiptIdentity
  ) throws -> FieldProvenance {
    guard CanonicalIdentifier.isValid(id), artifactSHA256 == identity.artifactSHA256,
      profileID == identity.profileID, adapterVersion == identity.adapterVersion,
      columnOrdinal.map({ $0 >= 0 }) ?? true
    else { throw HealthError.invalid }
    let locator = SourceLocator(
      containerMember: containerMember, table: table, recordKey: recordKey,
      columnOrdinal: columnOrdinal, columnName: columnName)
    guard id == CanonicalStagingID.field(stagingID: receipt, locator: locator) else {
      throw HealthError.invalid
    }
    return FieldProvenance(
      artifactSHA256: artifactSHA256, profileID: profileID, adapterVersion: adapterVersion,
      locator: locator, deterministicID: id)
  }

  private static func sourceTemporal(_ row: Row) throws -> SourceTemporal {
    let local = try SourceLocalDateTime(
      date: SourceLocalDate(year: row.int(6), month: row.int(7), day: row.int(8)),
      hour: row.int(9), minute: row.int(10), second: row.int(11), millisecond: row.int(12))
    let instant = UTCInstant(epochMilliseconds: row.int64(5))
    let precision = try enumValue(SourceTemporalPrecision.self, row.text(15))
    switch row.text(13) {
    case "iana":
      return try SourceTemporal.validatingPersistedIANA(
        instant: instant, localDateTime: local, identifier: row.text(14), precision: precision,
        resolvedOffsetSeconds: row.int(16))
    case "fixed":
      guard let offset = Int(row.text(14)), String(offset) == row.text(14) else {
        throw HealthError.invalid
      }
      return try SourceTemporal(
        instant: instant, localDateTime: local,
        timeZone: SourceTimeZone(fixedOffsetSeconds: offset), precision: precision,
        resolvedOffsetSeconds: row.int(16))
    default:
      throw HealthError.invalid
    }
  }

  private enum HealthError: Error { case invalid }

  private struct Row {
    private static let maximumTextBytes = 262_144
    private let values: [Value]

    init(statement: OpaquePointer) {
      values = (0..<sqlite3_column_count(statement)).map { column -> Value in
        switch sqlite3_column_type(statement, column) {
        case SQLITE_NULL: return Value.null
        case SQLITE_INTEGER: return Value.integer(sqlite3_column_int64(statement, column))
        case SQLITE_TEXT:
          guard let pointer = sqlite3_column_text(statement, column) else { return Value.invalid }
          let byteCount = sqlite3_column_bytes(statement, column)
          guard byteCount >= 0, byteCount <= Self.maximumTextBytes else { return Value.invalid }
          let data = Data(bytes: pointer, count: Int(byteCount))
          guard !data.contains(0), let value = String(data: data, encoding: .utf8) else {
            return Value.invalid
          }
          return Value.text(value)
        case SQLITE_BLOB:
          let byteCount = sqlite3_column_bytes(statement, column)
          guard byteCount >= 0, byteCount <= 67_108_864 else { return Value.invalid }
          guard byteCount > 0, let pointer = sqlite3_column_blob(statement, column) else {
            return byteCount == 0 ? Value.blob(Data()) : Value.invalid
          }
          return Value.blob(Data(bytes: pointer, count: Int(byteCount)))
        default: return Value.invalid
        }
      }
    }

    private enum Value {
      case null
      case integer(Int64)
      case text(String)
      case blob(Data)
      case invalid
    }

    func text(_ column: Int32) -> String {
      guard case .text(let value) = values[Int(column)] else { return "" }
      return value
    }
    func optionalText(_ column: Int32) -> String? {
      guard case .null = values[Int(column)] else { return text(column) }
      return nil
    }
    func optionalInt(_ column: Int32) -> Int? {
      switch values[Int(column)] {
      case .null:
        return nil
      case .integer(let value):
        return Int(exactly: value)
      default:
        return nil
      }
    }
    func int(_ column: Int32) -> Int { Int(int64(column)) }
    func int64(_ column: Int32) -> Int64 {
      guard case .integer(let value) = values[Int(column)] else { return .min }
      return value
    }
    func blob(_ column: Int32) -> Data {
      guard case .blob(let value) = values[Int(column)] else { return Data() }
      return value
    }
    func textColumns(_ columns: [Int]) -> Bool {
      columns.allSatisfy {
        if case .text = values[$0] { return true }
        return false
      }
    }
    func integerColumns(_ columns: [Int]) -> Bool {
      columns.allSatisfy {
        if case .integer = values[$0] { return true }
        return false
      }
    }
    func blobColumns(_ columns: [Int]) -> Bool {
      columns.allSatisfy {
        if case .blob = values[$0] { return true }
        return false
      }
    }
    func nullOrText(_ column: Int) -> Bool {
      switch values[column] {
      case .null, .text: return true
      default: return false
      }
    }
    func nullOrInteger(_ column: Int) -> Bool {
      switch values[column] {
      case .null, .integer: return true
      default: return false
      }
    }
  }

  private static func rows<T>(_ database: OpaquePointer, _ sql: String, _ body: (Row) throws -> T)
    throws -> [T]
  {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw HealthError.invalid
    }
    defer { sqlite3_finalize(statement) }
    var values: [T] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      values.append(try body(Row(statement: statement)))
    }
    guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
      throw HealthError.invalid
    }
    return values
  }

  private static func grouped<T>(
    _ database: OpaquePointer, _ sql: String, _ body: (Row) throws -> T
  ) throws -> [String: [T]] {
    var values: [String: [T]] = [:]
    for pair in try rows(
      database, sql,
      { row in
        (row.text(0), try body(row))
      })
    {
      values[pair.0, default: []].append(pair.1)
    }
    return values
  }

  private static func validateSourceLiteralOrdinals(_ database: OpaquePointer) throws {
    var expected: [String: Int] = [:]
    for row in try rows(
      database,
      "SELECT revision_id, ordinal FROM main.ledger_transaction_source_literal ORDER BY revision_id, ordinal",
      { $0 })
    {
      let revisionID = row.text(0)
      let ordinal = row.int(1)
      guard ordinal == expected[revisionID, default: 0] else { throw HealthError.invalid }
      expected[revisionID, default: 0] += 1
    }
  }

  private static func require<T>(_ value: T?) throws -> T {
    guard let value else { throw HealthError.invalid }
    return value
  }
  private static func enumValue<T: RawRepresentable>(_ type: T.Type, _ value: String) throws -> T
  where T.RawValue == String {
    guard let value = T(rawValue: value) else { throw HealthError.invalid }
    return value
  }
  private static func validateCategory(
    _ id: String?, kind: LedgerTransactionKind, categories: [String: LedgerCategory]
  ) throws {
    guard let id else {
      guard kind != .transfer else { return }
      return
    }
    let category = try require(categories[id])
    guard kind != .transfer, category.kind.accepts(kind) else { throw HealthError.invalid }
  }
}
