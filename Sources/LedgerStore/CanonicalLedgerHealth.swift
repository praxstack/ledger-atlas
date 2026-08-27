import CSQLite
import Foundation
import LedgerCore

/// Replays persisted native-ledger rows through the domain constructors.
/// Structural SQLite checks alone cannot establish financial validity.
package enum CanonicalLedgerHealth {
  package static func isHealthy(_ database: OpaquePointer) -> Bool {
    (try? validate(database)) != nil
  }

  static func validate(_ database: OpaquePointer) throws {
    try validateImportGraph(database)
    _ = try readSnapshot(database)
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
    let accounts = try Dictionary(
      uniqueKeysWithValues: rows(
        database,
        "SELECT account_id, name, currency_unit, origin_id, lifecycle FROM main.ledger_account"
      ) { row in
        let value = try LedgerAccount(
          id: row.text(0), name: row.text(1), currencyUnit: row.text(2),
          origin: try require(origins[row.text(3)]),
          lifecycle: try enumValue(LedgerLifecycleState.self, row.text(4)))
        return (value.id, value)
      })
    let categories = try Dictionary(
      uniqueKeysWithValues: rows(
        database, "SELECT category_id, name, kind, origin_id, lifecycle FROM main.ledger_category"
      ) { row in
        let value = try LedgerCategory(
          id: row.text(0), name: row.text(1),
          kind: try enumValue(LedgerCategoryKind.self, row.text(2)),
          origin: try require(origins[row.text(3)]),
          lifecycle: try enumValue(LedgerLifecycleState.self, row.text(4)))
        return (value.id, value)
      })
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
      transactions: snapshots.sorted {
        let lhs = $0.currentRevision.draft.occurredAt.instant
        let rhs = $1.currentRevision.draft.occurredAt.instant
        return lhs == rhs ? $0.id < $1.id : lhs > rhs
      },
      revisionHistory: revisions.values.sorted {
        ($0.transactionID, $0.revision) < ($1.transactionID, $1.revision)
      },
      undisplayedImportedEventCount: 0)
  }

  private static func validateImportGraph(_ database: OpaquePointer) throws {
    for row in try rows(
      database,
      "SELECT event_id, account_id, event_kind, amount_literal, currency_unit, instant_milliseconds, local_year, local_month, local_day, local_hour, local_minute, local_second, local_millisecond, timezone_kind, timezone_value, temporal_precision, resolved_offset_seconds, source_record_id, provenance_id FROM main.economic_event",
      { $0 })
    {
      guard CanonicalIdentifier.isValid(row.text(0)), CanonicalIdentifier.isValid(row.text(1)),
        CanonicalIdentifier.isValid(row.text(17)), CanonicalIdentifier.isValid(row.text(18)),
        ["income", "expense", "transfer_debit", "transfer_credit", "adjustment"]
          .contains(row.text(2))
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
        default: return Value.invalid
        }
      }
    }

    private enum Value { case null, integer(Int64), text(String), invalid }

    func text(_ column: Int32) -> String {
      guard case .text(let value) = values[Int(column)] else { return "" }
      return value
    }
    func optionalText(_ column: Int32) -> String? {
      guard case .null = values[Int(column)] else { return text(column) }
      return nil
    }
    func int(_ column: Int32) -> Int { Int(int64(column)) }
    func int64(_ column: Int32) -> Int64 {
      guard case .integer(let value) = values[Int(column)] else { return .min }
      return value
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
