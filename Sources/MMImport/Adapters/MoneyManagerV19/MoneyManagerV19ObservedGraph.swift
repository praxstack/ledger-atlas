import Foundation
import LedgerCore

/// Re-derives observed-v19 semantics from the authenticated staging graph.
/// Vendor table/column spellings stay in the adapter; the committer only invokes this check.
enum MoneyManagerV19ObservedGraph {
  static func validate(_ request: CanonicalCommitRequest, graph: StagingGraph) throws {
    let tableIDs = Dictionary(uniqueKeysWithValues: graph.tables.map { ($0.value.name, $0.key) })
    let recognizedTables = MoneyManagerV19Vocabulary.recognizedTables
    let recognizedTableIDs = Set(recognizedTables.compactMap { tableIDs[$0] })
    func hasAny(_ names: Set<String>) -> Bool { names.contains { tableIDs[$0] != nil } }
    guard hasAny(MoneyManagerV19Vocabulary.accountTables),
      hasAny(MoneyManagerV19Vocabulary.categoryTables),
      hasAny(MoneyManagerV19Vocabulary.currencyTables),
      hasAny(MoneyManagerV19Vocabulary.transactionTables),
      graph.fields.values.allSatisfy({ field in
        guard let record = graph.records[field.recordID] else { return false }
        guard recognizedTableIDs.contains(record.tableID) else { return true }
        if field.storageClass == CanonicalFieldStorageClass.text.rawValue {
          return String(data: field.payload, encoding: .utf8) != nil
        }
        return field.storageClass == CanonicalFieldStorageClass.integer.rawValue
          && field.payload.count == 8
      })
    else { throw CanonicalCommitError.unsafeMapping }

    func fields(for recordID: String) throws -> [String: (String, StagedFieldTarget)] {
      var result: [String: (String, StagedFieldTarget)] = [:]
      for (fieldID, field) in graph.fields where field.recordID == recordID {
        guard result.updateValue((fieldID, field), forKey: field.columnName) == nil else {
          throw CanonicalCommitError.unsafeMapping
        }
      }
      return result
    }
    func mappingLiteral(_ value: (String, StagedFieldTarget)?) -> String? {
      guard let field = value?.1 else { return nil }
      return MoneyManagerV19Vocabulary.mappingLiteral(
        storageClass: field.storageClass, payload: field.payload)
    }
    func aliased(
      _ values: [String: (String, StagedFieldTarget)], _ names: [String]
    ) -> (String, StagedFieldTarget)? {
      MoneyManagerV19Vocabulary.aliased(values, names)
    }
    func records(in table: String) -> [String] {
      guard let tableID = tableIDs[table] else { return [] }
      return graph.records.filter { $0.value.tableID == tableID }.map(\.key).sorted()
    }
    func records(inTables tables: [String]) -> [String] {
      tables.flatMap { records(in: $0) }
    }
    func uniqueUIDs(inTables tables: [String]) throws -> Set<String> {
      var values: Set<String> = []
      for recordID in records(inTables: tables) {
        guard
          let uid = mappingLiteral(
            aliased(try fields(for: recordID), MoneyManagerV19Vocabulary.uidAliases)),
          !uid.isEmpty, values.insert(uid).inserted
        else { throw CanonicalCommitError.unsafeMapping }
      }
      return values
    }

    let accountUIDs = try uniqueUIDs(inTables: Array(MoneyManagerV19Vocabulary.accountTables))
    let categoryUIDs = try uniqueUIDs(inTables: Array(MoneyManagerV19Vocabulary.categoryTables))
    var currencies: [String: String] = [:]
    for recordID in records(inTables: Array(MoneyManagerV19Vocabulary.currencyTables)) {
      let values = try fields(for: recordID)
      guard let uid = mappingLiteral(aliased(values, MoneyManagerV19Vocabulary.uidAliases)),
        let iso = mappingLiteral(aliased(values, MoneyManagerV19Vocabulary.isoAliases)),
        !uid.isEmpty, !iso.isEmpty, currencies.updateValue(iso, forKey: uid) == nil
      else { throw CanonicalCommitError.unsafeMapping }
    }

    let allTransactionIDs = Set(
      records(inTables: Array(MoneyManagerV19Vocabulary.transactionTables)))
    let eventsByRecord = Dictionary(grouping: request.events, by: \.sourceRecordID)
    let mappedRecordIDs = Set(eventsByRecord.keys)
    guard mappedRecordIDs.isSubset(of: allTransactionIDs)
    else { throw CanonicalCommitError.unsafeMapping }
    for (recordID, effects) in eventsByRecord {
      guard effects.count == 1,
        effects[0].eventID
          == (try? StableCanonicalID.event(sourceRecordID: recordID, effectOrdinal: 0))
      else {
        throw CanonicalCommitError.unsafeMapping
      }
      let sourceFieldIDs = Set(graph.fields.filter { $0.value.recordID == recordID }.map(\.key))
      guard effects.allSatisfy({ Set($0.sidecarReferences.map(\.sidecarID)) == sourceFieldIDs })
      else { throw CanonicalCommitError.unsafeMapping }
    }
    let eventTableIDs = Set(
      graph.records.filter { mappedRecordIDs.contains($0.key) }.map { $0.value.tableID })
    let receiptOwnedSubjectIDs = Set(
      graph.tables.filter { !eventTableIDs.contains($0.key) }.map(\.key)
        + graph.records.filter { !mappedRecordIDs.contains($0.key) }.map(\.key)
        + graph.fields.filter { !mappedRecordIDs.contains($0.value.recordID) }.map(\.key))
    guard request.observedV19ReceiptOwnedSubjectIDs == receiptOwnedSubjectIDs,
      !request.events.isEmpty || !receiptOwnedSubjectIDs.isEmpty
    else { throw CanonicalCommitError.unsafeMapping }

    var commonZone: SourceTimeZone?
    var transactionUIDs = Set<String>()
    for (recordID, effects) in eventsByRecord {
      let values = try fields(for: recordID)
      guard let amount = mappingLiteral(aliased(values, MoneyManagerV19Vocabulary.amountAliases)),
        let currencyUID = mappingLiteral(
          aliased(values, MoneyManagerV19Vocabulary.currencyUIDAliases)),
        let accountUID = mappingLiteral(aliased(values, MoneyManagerV19Vocabulary.assetAliases)),
        let categoryUID = mappingLiteral(
          aliased(values, MoneyManagerV19Vocabulary.categoryAliases)),
        let transactionUID = mappingLiteral(aliased(values, MoneyManagerV19Vocabulary.uidAliases)),
        !transactionUID.isEmpty, transactionUIDs.insert(transactionUID).inserted,
        let type = mappingLiteral(aliased(values, MoneyManagerV19Vocabulary.doTypeAliases)),
        let wdate = mappingLiteral(aliased(values, MoneyManagerV19Vocabulary.wdateAliases)),
        let zdate = mappingLiteral(aliased(values, MoneyManagerV19Vocabulary.zdateAliases)),
        accountUIDs.contains(accountUID), categoryUIDs.contains(categoryUID),
        currencies[currencyUID] != nil
      else { throw CanonicalCommitError.unsafeMapping }
      for event in effects {
        guard currencies[currencyUID] == event.amount.unitCode,
          amount == event.amount.amount.rawLiteral,
          event.accountID
            == (try? StableCanonicalID.account(
              profileID: request.expectedManifest.profileID, sourceAccountID: accountUID)),
          (type == "0" && event.kind == .income) || (type == "1" && event.kind == .expense),
          event.occurredAt.precision == .millisecond,
          observedLocalDateTime(zdate) == event.occurredAt.localDateTime,
          observedDay(wdate) == event.occurredAt.localDay
        else { throw CanonicalCommitError.unsafeMapping }
        if let commonZone {
          guard commonZone == event.occurredAt.timeZone else {
            throw CanonicalCommitError.unsafeMapping
          }
        } else {
          commonZone = event.occurredAt.timeZone
        }
        for binding in event.sourceBindings {
          if binding.semantic == .currency {
            guard
              MoneyManagerV19Vocabulary.currencyTables.contains(binding.provenance.locator.table),
              MoneyManagerV19Vocabulary.isoAliases.contains(
                binding.provenance.locator.columnName ?? ""),
              binding.provenance.locator.recordKey.isEmpty == false
            else { throw CanonicalCommitError.unsafeMapping }
            continue
          }
          let aliases: [String]
          switch binding.semantic {
          case .amount: aliases = MoneyManagerV19Vocabulary.amountAliases
          case .occurredAt: aliases = MoneyManagerV19Vocabulary.zdateAliases
          case .account: aliases = MoneyManagerV19Vocabulary.assetAliases
          case .kind: aliases = MoneyManagerV19Vocabulary.doTypeAliases
          default: throw CanonicalCommitError.unsafeMapping
          }
          guard aliased(values, aliases)?.0 == binding.provenance.deterministicID else {
            throw CanonicalCommitError.unsafeMapping
          }
        }
      }
    }
  }

  /// Mechanically decodes the vendor's local epoch-millisecond representation into wall-clock
  /// components. This does not interpret the literal as a UTC instant.
  static func observedLocalDateTime(_ literal: String) -> SourceLocalDateTime? {
    guard let milliseconds = Int64(literal) else { return nil }
    let civil = GregorianCivil.components(epochMilliseconds: milliseconds)
    guard let date = try? SourceLocalDate(year: civil.year, month: civil.month, day: civil.day)
    else { return nil }
    return try? SourceLocalDateTime(
      date: date, hour: civil.hour, minute: civil.minute, second: civil.second,
      millisecond: civil.millisecond)
  }

  static func observedDay(_ literal: String) -> SourceLocalDate? {
    let parts = literal.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]),
      let day = Int(parts[2])
    else { return nil }
    return try? SourceLocalDate(year: year, month: month, day: day)
  }
}
