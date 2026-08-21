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
