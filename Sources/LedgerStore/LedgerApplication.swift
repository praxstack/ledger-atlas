import CoreFoundation
import CryptoKit
import Foundation
import LedgerCore

// ponytail: a portable package is capped at 64 MiB, 64 levels, and one million JSON
// structural tokens; replace JSONSerialization with a streaming decoder before raising them.
private let maximumPortablePackageBytes = 64 * 1_024 * 1_024
private let maximumPortableJSONNesting = 64
private let maximumPortableJSONStringBytes = 1_024 * 1_024
private let maximumPortableJSONStructuralTokens = 1_000_000

public struct LedgerApplication: LedgerClient {
  public enum Error: Swift.Error, Equatable, Sendable {
    case invalidCommand
    case ledgerUnchanged
  }

  private let store: LedgerStore

  public init(store: LedgerStore) {
    self.store = store
  }

  public func snapshot() throws -> LedgerStore.LedgerReadSnapshot {
    try store.readSnapshot()
  }

  public func checksum() throws -> String {
    try store.semanticChecksum()
  }

  public func createAccount(_ account: LedgerAccount) throws {
    try store.createAccount(account)
  }

  public func createCategory(_ category: LedgerCategory) throws {
    try store.createCategory(category)
  }

  public func createTransaction(
    idempotencyKey: String, draft: LedgerTransactionDraft, createdAt: UTCInstant
  ) throws -> LedgerTransactionRevision {
    try store.createTransaction(
      .init(idempotencyKey: idempotencyKey, draft: draft, createdAt: createdAt)
    ).revision
  }

  public func correctTransaction(
    transactionID: String, expectedCurrentRevisionID: String, draft: LedgerTransactionDraft,
    createdAt: UTCInstant
  ) throws -> LedgerTransactionRevision {
    try store.correctTransaction(
      .init(
        transactionID: transactionID, expectedCurrentRevisionID: expectedCurrentRevisionID,
        draft: draft, createdAt: createdAt)
    ).revision
  }

  public func tombstoneTransaction(
    transactionID: String, expectedCurrentRevisionID: String, createdAt: UTCInstant
  ) throws -> LedgerTransactionRevision {
    try store.tombstoneTransaction(
      .init(
        transactionID: transactionID, expectedCurrentRevisionID: expectedCurrentRevisionID,
        createdAt: createdAt)
    ).revision
  }

  public func createTransfer(
    idempotencyKey: String, sourceAccountID: String, destinationAccountID: String,
    sourceAmount: CurrencyAmount, destinationAmount: CurrencyAmount, conversion: LedgerConversion?,
    fee: CurrencyAmount?, feeAccountID: String?, occurredAt: SourceTemporal, origin: LedgerOrigin,
    createdAt: UTCInstant
  ) throws -> (transfer: LedgerTransactionRevision, fee: LedgerTransactionRevision?) {
    if (fee == nil) != (feeAccountID == nil) { throw Error.invalidCommand }
    if let conversion {
      guard conversion.sourceAmount == sourceAmount, conversion.convertedAmount == destinationAmount
      else { throw Error.invalidCommand }
    } else if sourceAmount != destinationAmount {
      throw Error.invalidCommand
    }
    let source = try LedgerTransactionEffect(
      accountID: sourceAccountID, direction: .decrease, amount: sourceAmount)
    let destination = try LedgerTransactionEffect(
      accountID: destinationAccountID, direction: .increase, amount: destinationAmount)
    let literals = try conversion?.literals ?? []
    let draft = try LedgerTransactionDraft(
      effects: [source, destination], categoryID: nil, kind: .transfer, occurredAt: occurredAt,
      roundingPolicy: conversion?.rounding, sourceLiterals: literals, origin: origin)
    var feeRequest: LedgerStore.CreateTransactionRequest?
    if let fee, let feeAccountID {
      let feeDraft = try LedgerTransactionDraft(
        effects: [
          try LedgerTransactionEffect(
            accountID: feeAccountID, direction: .decrease, amount: fee)
        ], categoryID: nil, kind: .adjustment, occurredAt: occurredAt, origin: origin)
      let feeKey = SHA256.hash(data: Data((idempotencyKey + ":fee").utf8)).map {
        String(format: "%02x", $0)
      }.joined()
      feeRequest = .init(idempotencyKey: feeKey, draft: feeDraft, createdAt: createdAt)
    }
    let result = try store.createTransfer(
      transfer: .init(idempotencyKey: idempotencyKey, draft: draft, createdAt: createdAt),
      fee: feeRequest)
    return (result.transfer.revision, result.fee?.revision)
  }

  public func createSplit(
    idempotencyKey: String, accountID: String, parentAmount: CurrencyAmount,
    components: [(amount: CurrencyAmount, categoryID: String)], occurredAt: SourceTemporal,
    origin: LedgerOrigin, createdAt: UTCInstant
  ) throws -> [LedgerTransactionRevision] {
    var total = try ExactDecimal("0")
    for component in components {
      guard component.amount.unitCode == parentAmount.unitCode else { throw Error.invalidCommand }
      total = try total.adding(component.amount.amount)
    }
    guard total == parentAmount.amount, !components.isEmpty else { throw Error.invalidCommand }
    var requests: [LedgerStore.CreateTransactionRequest] = []
    for (index, component) in components.enumerated() {
      let draft = try LedgerTransactionDraft(
        effects: [
          try LedgerTransactionEffect(
            accountID: accountID, direction: .decrease, amount: component.amount)
        ], categoryID: component.categoryID, kind: .expense, occurredAt: occurredAt, origin: origin)
      let childKey = SHA256.hash(data: Data("\(idempotencyKey).\(index)".utf8)).map {
        String(format: "%02x", $0)
      }.joined()
      requests.append(.init(idempotencyKey: childKey, draft: draft, createdAt: createdAt))
    }
    return try store.createLinkedTransactions(requests, linkKind: .split).map(\.revision)
  }

  public func createInstallmentPlan(
    _ plan: LedgerInstallmentPlan, occurredAt: SourceTemporal, createdAt: UTCInstant
  ) throws -> [LedgerTransactionRevision] {
    guard plan.lifecycle == .active, plan.occurrenceCount > 0 else { throw Error.invalidCommand }
    let share = try plan.principal.amount.divided(
      by: ExactDecimal(String(plan.occurrenceCount)), scale: plan.principal.amount.sourceScale,
      rounding: .towardZero)
    var allocated = try ExactDecimal("0")
    var requests: [LedgerStore.CreateTransactionRequest] = []
    for index in 0..<plan.occurrenceCount {
      let remaining = try plan.principal.amount.subtracting(allocated)
      let portion = index == plan.occurrenceCount - 1 ? remaining : share
      guard portion > (try ExactDecimal("0")) else { throw Error.invalidCommand }
      allocated = try allocated.adding(
        index == plan.occurrenceCount - 1 ? ExactDecimal("0") : share)
      if index == plan.occurrenceCount - 1 { allocated = plan.principal.amount }
      let amount = try CurrencyAmount(unitCode: plan.principal.unitCode, amount: portion)
      var date = occurredAt.localDateTime.date
      if index > 0 {
        date = try advance(date, frequency: .monthly, interval: index, dayOfMonth: date.day)
      }
      let when = try SourceTemporal(
        resolving: SourceLocalDateTime(
          date: date, hour: occurredAt.localDateTime.hour,
          minute: occurredAt.localDateTime.minute),
        in: occurredAt.timeZone, precision: occurredAt.precision)
      let draft = try LedgerTransactionDraft(
        effects: [
          try LedgerTransactionEffect(
            accountID: plan.accountID, direction: .decrease, amount: amount)
        ], categoryID: plan.categoryID, kind: .expense, occurredAt: when,
        sourceLiterals: [
          try LedgerSourceLiteral(field: "installment.planID", literal: plan.id),
          try LedgerSourceLiteral(field: "installment.ordinal", literal: String(index)),
        ], origin: plan.origin)
      let key = SHA256.hash(data: Data("installment:\(plan.id):\(index)".utf8)).map {
        String(format: "%02x", $0)
      }.joined()
      requests.append(.init(idempotencyKey: key, draft: draft, createdAt: createdAt))
    }
    return try store.createInstallment(requests, plan: plan).map(\.revision)
  }

  public func createRecurrence(_ rule: LedgerRecurrenceRule) throws {
    try store.persistRecurrence(rule)
  }

  public func updateRecurrence(_ rule: LedgerRecurrenceRule, scope: LedgerEditScope) throws {
    guard scope == .thisAndFuture || scope == .thisOccurrence else { throw Error.invalidCommand }
    if scope == .thisOccurrence {
      guard let existing = try snapshot().recurrenceRules.first(where: { $0.id == rule.id }) else {
        throw Error.invalidCommand
      }
      var skipped = existing.skippedDates
      for date in rule.skippedDates where !skipped.contains(date) { skipped.append(date) }
      try store.persistRecurrence(
        LedgerRecurrenceRule(
          id: existing.id, origin: existing.origin, accountID: existing.accountID,
          categoryID: existing.categoryID, kind: existing.kind, amount: existing.amount,
          frequency: existing.frequency, interval: existing.interval,
          dayOfMonth: existing.dayOfMonth, timeZone: existing.timeZone, start: existing.start,
          until: existing.until, paused: existing.paused, skippedDates: skipped,
          lifecycle: existing.lifecycle))
      return
    }
    try store.persistRecurrence(rule)
  }

  public func generateOccurrences(
    _ rule: LedgerRecurrenceRule, through end: SourceLocalDate, createdAt: UTCInstant
  ) throws -> [LedgerTransactionRevision] {
    guard !rule.paused, rule.lifecycle == .active else { return [] }
    var created: [LedgerTransactionRevision] = []
    var cursor = rule.start
    var index = 0
    while !cursor.isAfter(end) {
      if let until = rule.until, cursor.isAfter(until) { break }
      if !rule.skippedDates.contains(cursor) {
        let occurred = try SourceTemporal(
          resolving: SourceLocalDateTime(date: cursor), in: rule.timeZone, precision: .day)
        let draft = try LedgerTransactionDraft(
          effects: [
            try LedgerTransactionEffect(
              accountID: rule.accountID,
              direction: rule.kind == .income ? .increase : .decrease, amount: rule.amount)
          ], categoryID: rule.categoryID, kind: rule.kind, occurredAt: occurred,
          sourceLiterals: [try LedgerSourceLiteral(field: "recurrence.ruleID", literal: rule.id)],
          origin: rule.origin)
        let key = SHA256.hash(
          data: Data("recurrence:\(rule.id):\(cursor.year)-\(cursor.month)-\(cursor.day)".utf8)
        ).map { String(format: "%02x", $0) }.joined()
        let revision = try createTransaction(
          idempotencyKey: key, draft: draft, createdAt: createdAt)
        created.append(revision)
        if created.count > 1 {
          try store.persistLink(
            LedgerTransactionLink(
              id: StableLedgerID.link(
                fromTransactionID: created[0].transactionID,
                toTransactionID: revision.transactionID, kind: .recurring),
              fromTransactionID: created[0].transactionID,
              toTransactionID: revision.transactionID, kind: .recurring))
        }
      }
      cursor = try advance(
        cursor, frequency: rule.frequency, interval: rule.interval, dayOfMonth: rule.dayOfMonth)
      index += 1
      if index > 366 { break }
    }
    return created
  }

  public func createBudget(_ budget: LedgerBudget) throws {
    try store.persistBudget(budget)
  }

  public func search(_ query: LedgerSearchQuery) throws -> [LedgerTransactionSnapshot] {
    Self.search(query, in: try store.readSnapshot())
  }

  public static func search(
    _ query: LedgerSearchQuery, in snapshot: LedgerStore.LedgerReadSnapshot
  ) -> [LedgerTransactionSnapshot] {
    snapshot.transactions.filter { matches($0, query: query) }
  }

  static func matches(_ snapshot: LedgerTransactionSnapshot, query: LedgerSearchQuery) -> Bool {
    let revision = snapshot.currentRevision
    let draft = revision.draft
    if !query.includeTombstones, revision.lifecycle == .tombstoned { return false }
    if let lifecycle = query.lifecycle, revision.lifecycle != lifecycle { return false }
    if let accountID = query.accountID,
      !draft.effects.contains(where: { $0.accountID == accountID })
    {
      return false
    }
    if let categoryID = query.categoryID, draft.categoryID != categoryID { return false }
    if let kind = query.kind, draft.kind != kind { return false }
    if let noteContains = query.noteContains {
      guard let note = draft.note, note.localizedCaseInsensitiveContains(noteContains) else {
        return false
      }
    }
    let tags = draft.sourceLiterals.filter {
      $0.field == "tag" || $0.field.hasPrefix("tag.")
    }.map(\.literal)
    if let tagContains = query.tagContains {
      guard tags.contains(where: { $0.localizedCaseInsensitiveContains(tagContains) }) else {
        return false
      }
    }
    if let textContains = query.textContains {
      let haystacks =
        [draft.note, draft.kind.rawValue, revision.lifecycle.rawValue].compactMap {
          $0
        } + tags
      guard haystacks.contains(where: { $0.localizedCaseInsensitiveContains(textContains) }) else {
        return false
      }
    }
    let day = draft.occurredAt.localDateTime.date
    if let start = query.occurredOnOrAfter, day < start { return false }
    if let end = query.occurredOnOrBefore, end < day { return false }
    if query.minimumAmount != nil || query.maximumAmount != nil || query.unitCode != nil {
      let amounts = draft.effects.filter { effect in
        query.unitCode.map { $0 == effect.amount.unitCode } ?? true
      }.map(\.amount.amount)
      guard !amounts.isEmpty else { return false }
      if let minimum = query.minimumAmount, amounts.allSatisfy({ $0 < minimum }) { return false }
      if let maximum = query.maximumAmount, amounts.allSatisfy({ $0 > maximum }) { return false }
    }
    if let hasCorrections = query.hasCorrections {
      let corrected = revision.revision > 1 || revision.predecessorID != nil
      if corrected != hasCorrections { return false }
    }
    return true
  }

  public func report(unitCode: String) throws -> LedgerReport {
    try Self.report(from: store.readSnapshot(), unitCode: unitCode)
  }

  public func makeProjection(unitCode: String) throws -> LedgerProjection {
    LedgerProjection(report: try report(unitCode: unitCode))
  }

  public static func report(
    from snapshot: LedgerStore.LedgerReadSnapshot, unitCode: String
  ) throws -> LedgerReport {
    var totals: [LedgerTransactionKind: (ExactDecimal, Int)] = [:]
    for transaction in snapshot.transactions where transaction.currentRevision.lifecycle == .active
    {
      let draft = transaction.currentRevision.draft
      let matching = draft.effects.filter { $0.amount.unitCode == unitCode }
      guard !matching.isEmpty else { continue }
      var entry = totals[draft.kind]
      if entry == nil { entry = (try ExactDecimal("0"), 0) }
      for effect in matching {
        entry!.0 = try entry!.0.adding(effect.amount.amount)
      }
      entry!.1 += 1
      totals[draft.kind] = entry
    }
    let rows = LedgerTransactionKind.allCases.compactMap { kind -> LedgerReportRow? in
      guard let entry = totals[kind] else { return nil }
      return LedgerReportRow(
        id: kind.rawValue, label: kind.rawValue, amountLiteral: entry.0.rawLiteral,
        unitCode: unitCode, count: entry.1)
    }
    var total = try ExactDecimal("0")
    for row in rows { total = try total.adding(ExactDecimal(row.amountLiteral)) }
    return LedgerReport(
      title: "Activity by kind", rows: rows, totalLiteral: total.rawLiteral, unitCode: unitCode,
      inventory: inventory(from: snapshot))
  }

  public static func inventory(from snapshot: LedgerStore.LedgerReadSnapshot) -> [LedgerReportRow] {
    let transferCount = snapshot.transactions.filter {
      $0.currentRevision.draft.kind == .transfer
    }.count
    let splitIDs = Set(
      snapshot.transactions.flatMap(\.links).filter { $0.kind == .split }.flatMap {
        [$0.fromTransactionID, $0.toTransactionID]
      })
    let correctionCount = snapshot.transactions.filter { $0.currentRevision.revision > 1 }.count
    let tombstoneCount = snapshot.transactions.filter {
      $0.currentRevision.lifecycle == .tombstoned
    }.count
    let currencies = Set(snapshot.accounts.map(\.currencyUnit)).count
    return [
      LedgerReportRow(
        id: "transfers", label: "Transfers", amountLiteral: "0", unitCode: "", count: transferCount),
      LedgerReportRow(
        id: "splits", label: "Splits", amountLiteral: "0", unitCode: "", count: splitIDs.count),
      LedgerReportRow(
        id: "installments", label: "Installments", amountLiteral: "0", unitCode: "",
        count: snapshot.installmentPlans.count),
      LedgerReportRow(
        id: "recurrence", label: "Recurrence", amountLiteral: "0", unitCode: "",
        count: snapshot.recurrenceRules.count),
      LedgerReportRow(
        id: "budgets", label: "Budgets", amountLiteral: "0", unitCode: "",
        count: snapshot.budgets.count),
      LedgerReportRow(
        id: "currencies", label: "Currencies", amountLiteral: "0", unitCode: "", count: currencies),
      LedgerReportRow(
        id: "corrections", label: "Corrections", amountLiteral: "0", unitCode: "",
        count: correctionCount),
      LedgerReportRow(
        id: "tombstones", label: "Tombstones", amountLiteral: "0", unitCode: "",
        count: tombstoneCount),
    ]
  }

  public func exportPackage() throws -> (manifest: LedgerExportManifest, payload: Data) {
    let export = try store.portablePackageExportSnapshot()
    let snapshot = export.ledger
    guard export.isRepresentable,
      snapshot.undisplayedImportedEventCount == 0, !export.hasImportHistory,
      snapshot.preservedSource.isEmpty,
      !hasUnsupportedPortableProvenance(snapshot)
    else {
      // The portable package cannot yet encode the canonical receipt/provenance graph.
      // Imported ledgers must use the exact canonical SQLite backup instead of losing it.
      throw Error.invalidCommand
    }
    var links: [String: LedgerTransactionLink] = [:]
    for link in snapshot.transactions.flatMap(\.links) {
      if let existing = links[link.id], existing != link { throw Error.invalidCommand }
      links[link.id] = link
    }
    let package = LedgerCanonicalPackage(
      formatVersion: LedgerPortablePackageFormat.version,
      formatFingerprint: LedgerPortablePackageFormat.fingerprint, accounts: snapshot.accounts,
      categories: snapshot.categories, revisions: snapshot.revisionHistory,
      links: links.values.sorted { $0.id < $1.id }, recurrenceRules: snapshot.recurrenceRules,
      budgets: snapshot.budgets, installmentPlans: snapshot.installmentPlans)
    let payload = try encode(package)
    guard payload.count <= maximumPortablePackageBytes else { throw Error.invalidCommand }
    let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    let manifest = LedgerExportManifest(
      formatVersion: LedgerPortablePackageFormat.version,
      formatFingerprint: LedgerPortablePackageFormat.fingerprint, payloadSHA256: digest,
      createdAtMilliseconds: 0)
    return (manifest, payload)
  }

  public func materializeImportedEvents() throws {
    try store.materializeImportedEvents()
  }

  public func importPackage(manifest: LedgerExportManifest, payload: Data) throws {
    guard payload.count <= maximumPortablePackageBytes else { throw Error.invalidCommand }
    let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    guard digest == manifest.payloadSHA256, supportedPackageManifest(manifest)
    else { throw Error.invalidCommand }
    guard try store.isEmptyForPortablePackageImport() else { throw Error.invalidCommand }
    let existing = try store.readSnapshot()
    guard !snapshotHasProductRows(existing) else { throw Error.invalidCommand }
    do {
      try store.applyExport(try decodePackage(payload, manifest: manifest))
    } catch {
      throw Error.invalidCommand
    }
  }
}

private func snapshotHasProductRows(_ snapshot: LedgerStore.LedgerReadSnapshot) -> Bool {
  !snapshot.accounts.isEmpty || !snapshot.transactions.isEmpty || !snapshot.categories.isEmpty
    || !snapshot.recurrenceRules.isEmpty || !snapshot.budgets.isEmpty
    || !snapshot.installmentPlans.isEmpty
}

private func supportedPackageManifest(_ manifest: LedgerExportManifest) -> Bool {
  (manifest.formatVersion == LedgerPortablePackageFormat.version
    && manifest.formatFingerprint == LedgerPortablePackageFormat.fingerprint)
    || (manifest.formatVersion == LedgerPortablePackageFormat.legacyV10SchemaVersion
      && manifest.formatFingerprint == LedgerPortablePackageFormat.legacyV10SchemaFingerprint)
}

public struct IOSFacingLedgerClient: LedgerClient {
  private let application: LedgerApplication

  public init(store: LedgerStore) {
    application = LedgerApplication(store: store)
  }

  public func createAccount(_ account: LedgerAccount) throws {
    try application.createAccount(account)
  }
  public func createCategory(_ category: LedgerCategory) throws {
    try application.createCategory(category)
  }
  public func createTransaction(
    idempotencyKey: String, draft: LedgerTransactionDraft, createdAt: UTCInstant
  ) throws -> LedgerTransactionRevision {
    try application.createTransaction(
      idempotencyKey: idempotencyKey, draft: draft, createdAt: createdAt)
  }
  public func correctTransaction(
    transactionID: String, expectedCurrentRevisionID: String, draft: LedgerTransactionDraft,
    createdAt: UTCInstant
  ) throws -> LedgerTransactionRevision {
    try application.correctTransaction(
      transactionID: transactionID, expectedCurrentRevisionID: expectedCurrentRevisionID,
      draft: draft, createdAt: createdAt)
  }
  public func tombstoneTransaction(
    transactionID: String, expectedCurrentRevisionID: String, createdAt: UTCInstant
  ) throws -> LedgerTransactionRevision {
    try application.tombstoneTransaction(
      transactionID: transactionID, expectedCurrentRevisionID: expectedCurrentRevisionID,
      createdAt: createdAt)
  }
  public func createTransfer(
    idempotencyKey: String, sourceAccountID: String, destinationAccountID: String,
    sourceAmount: CurrencyAmount, destinationAmount: CurrencyAmount, conversion: LedgerConversion?,
    fee: CurrencyAmount?, feeAccountID: String?, occurredAt: SourceTemporal, origin: LedgerOrigin,
    createdAt: UTCInstant
  ) throws -> (transfer: LedgerTransactionRevision, fee: LedgerTransactionRevision?) {
    try application.createTransfer(
      idempotencyKey: idempotencyKey, sourceAccountID: sourceAccountID,
      destinationAccountID: destinationAccountID, sourceAmount: sourceAmount,
      destinationAmount: destinationAmount, conversion: conversion, fee: fee,
      feeAccountID: feeAccountID, occurredAt: occurredAt, origin: origin, createdAt: createdAt)
  }
  public func createSplit(
    idempotencyKey: String, accountID: String, parentAmount: CurrencyAmount,
    components: [(amount: CurrencyAmount, categoryID: String)], occurredAt: SourceTemporal,
    origin: LedgerOrigin, createdAt: UTCInstant
  ) throws -> [LedgerTransactionRevision] {
    try application.createSplit(
      idempotencyKey: idempotencyKey, accountID: accountID, parentAmount: parentAmount,
      components: components, occurredAt: occurredAt, origin: origin, createdAt: createdAt)
  }
  public func createInstallmentPlan(
    _ plan: LedgerInstallmentPlan, occurredAt: SourceTemporal, createdAt: UTCInstant
  ) throws -> [LedgerTransactionRevision] {
    try application.createInstallmentPlan(plan, occurredAt: occurredAt, createdAt: createdAt)
  }
  public func createRecurrence(_ rule: LedgerRecurrenceRule) throws {
    try application.createRecurrence(rule)
  }
  public func updateRecurrence(_ rule: LedgerRecurrenceRule, scope: LedgerEditScope) throws {
    try application.updateRecurrence(rule, scope: scope)
  }
  public func generateOccurrences(
    _ rule: LedgerRecurrenceRule, through end: SourceLocalDate, createdAt: UTCInstant
  ) throws -> [LedgerTransactionRevision] {
    try application.generateOccurrences(rule, through: end, createdAt: createdAt)
  }
  public func createBudget(_ budget: LedgerBudget) throws { try application.createBudget(budget) }
  public func search(_ query: LedgerSearchQuery) throws -> [LedgerTransactionSnapshot] {
    try application.search(query)
  }
  public func report(unitCode: String) throws -> LedgerReport {
    try application.report(unitCode: unitCode)
  }
  public func makeProjection(unitCode: String) throws -> LedgerProjection {
    try application.makeProjection(unitCode: unitCode)
  }
  public func checksum() throws -> String { try application.checksum() }
  public func exportPackage() throws -> (manifest: LedgerExportManifest, payload: Data) {
    try application.exportPackage()
  }
  public func importPackage(manifest: LedgerExportManifest, payload: Data) throws {
    try application.importPackage(manifest: manifest, payload: payload)
  }
}

extension SourceLocalDate {
  fileprivate func isAfter(_ other: SourceLocalDate) -> Bool {
    (year, month, day) > (other.year, other.month, other.day)
  }
}

private func advance(
  _ date: SourceLocalDate, frequency: LedgerRecurrenceFrequency, interval: Int, dayOfMonth: Int?
) throws -> SourceLocalDate {
  switch frequency {
  case .daily:
    return try addDays(date, interval)
  case .weekly:
    return try addDays(date, 7 * interval)
  case .monthly, .yearly:
    let monthDelta = frequency == .monthly ? interval : 0
    let yearDelta = frequency == .yearly ? interval : 0
    let total = date.year * 12 + (date.month - 1) + monthDelta + yearDelta * 12
    let year = total / 12
    let month = total % 12 + 1
    let wanted = dayOfMonth ?? date.day
    let last = lastDay(year: year, month: month)
    return try SourceLocalDate(year: year, month: month, day: min(wanted, last))
  }
}

private func addDays(_ date: SourceLocalDate, _ days: Int) throws -> SourceLocalDate {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(secondsFromGMT: 0)!
  let components = DateComponents(year: date.year, month: date.month, day: date.day)
  guard let value = calendar.date(from: components),
    let next = calendar.date(byAdding: .day, value: days, to: value)
  else { throw LedgerApplication.Error.invalidCommand }
  let parts = calendar.dateComponents([.year, .month, .day], from: next)
  return try SourceLocalDate(year: parts.year!, month: parts.month!, day: parts.day!)
}

private func encode(_ package: LedgerCanonicalPackage) throws -> Data {
  let accounts = package.accounts.map {
    [
      "id": $0.id, "name": $0.name, "currencyUnit": $0.currencyUnit, "originID": $0.origin.id,
      "originLabel": $0.origin.label, "lifecycle": $0.lifecycle.rawValue,
    ]
  }
  let categories = package.categories.map {
    [
      "id": $0.id, "name": $0.name, "kind": $0.kind.rawValue, "originID": $0.origin.id,
      "originLabel": $0.origin.label, "lifecycle": $0.lifecycle.rawValue,
    ]
  }
  var revisions: [[String: Any]] = []
  for revision in package.revisions {
    let draft = revision.draft
    revisions.append([
      "id": revision.id,
      "transactionID": revision.transactionID,
      "revision": revision.revision,
      "predecessorID": revision.predecessorID as Any,
      "lifecycle": revision.lifecycle.rawValue,
      "createdAt": revision.createdAt.epochMilliseconds,
      "kind": draft.kind.rawValue,
      "categoryID": draft.categoryID as Any,
      "note": draft.note as Any,
      "roundingPolicy": draft.roundingPolicy?.rawValue as Any,
      "originID": draft.origin.id,
      "originLabel": draft.origin.label,
      "occurredAt": try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(draft.occurredAt)),
      "effects": draft.effects.map {
        [
          "accountID": $0.accountID, "direction": $0.direction.rawValue,
          "amount": $0.amount.amount.rawLiteral, "unit": $0.amount.unitCode,
        ]
      },
      "literals": draft.sourceLiterals.map {
        ["field": $0.field, "literal": $0.literal]
      },
    ])
  }
  let links = package.links.map {
    [
      "id": $0.id, "from": $0.fromTransactionID, "to": $0.toTransactionID,
      "kind": $0.kind.rawValue,
    ]
  }
  let object: [String: Any] = [
    "formatVersion": package.formatVersion,
    "formatFingerprint": package.formatFingerprint,
    "accounts": accounts,
    "categories": categories,
    "revisions": revisions,
    "links": links,
    "recurrenceRules": package.recurrenceRules.map { rule -> [String: Any] in
      var row: [String: Any] = [
        "id": rule.id, "originID": rule.origin.id, "originLabel": rule.origin.label,
        "accountID": rule.accountID, "kind": rule.kind.rawValue,
        "categoryID": rule.categoryID as Any, "dayOfMonth": rule.dayOfMonth as Any,
        "amount": rule.amount.amount.rawLiteral, "unit": rule.amount.unitCode,
        "frequency": rule.frequency.rawValue, "interval": rule.interval, "paused": rule.paused,
        "lifecycle": rule.lifecycle.rawValue, "startYear": rule.start.year,
        "startMonth": rule.start.month, "startDay": rule.start.day,
        "untilYear": rule.until?.year as Any, "untilMonth": rule.until?.month as Any,
        "untilDay": rule.until?.day as Any,
        "skipped": rule.skippedDates.map {
          ["year": $0.year, "month": $0.month, "day": $0.day] as [String: Int]
        },
      ]
      if let identifier = rule.timeZone.ianaIdentifier {
        row["timezoneKind"] = "iana"
        row["timezoneValue"] = identifier
      } else if let offset = rule.timeZone.fixedOffsetSeconds {
        row["timezoneKind"] = "fixed"
        row["timezoneValue"] = String(offset)
      }
      return row
    },
    "budgets": package.budgets.map {
      [
        "id": $0.id, "originID": $0.origin.id, "originLabel": $0.origin.label, "name": $0.name,
        "categoryID": $0.categoryID, "amount": $0.amount.amount.rawLiteral,
        "unit": $0.amount.unitCode, "period": $0.period.rawValue, "rollover": $0.rollover,
        "startYear": $0.start.year, "startMonth": $0.start.month, "startDay": $0.start.day,
        "lifecycle": $0.lifecycle.rawValue,
      ]
    },
    "installmentPlans": package.installmentPlans.map {
      [
        "id": $0.id, "originID": $0.origin.id, "originLabel": $0.origin.label,
        "accountID": $0.accountID, "categoryID": $0.categoryID as Any,
        "principal": $0.principal.amount.rawLiteral, "unit": $0.principal.unitCode,
        "occurrenceCount": $0.occurrenceCount, "completedCount": $0.completedCount,
        "lifecycle": $0.lifecycle.rawValue,
      ]
    },
    "preservedSource": package.preservedSource.map {
      [
        "table": $0.table, "recordKey": $0.recordKey, "columnName": $0.columnName,
        "storageClass": $0.storageClass, "payload": $0.payload.base64EncodedString(),
        "reasonCode": $0.reasonCode,
      ]
    },
  ]
  return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func decodePackage(_ data: Data, manifest: LedgerExportManifest) throws
  -> LedgerCanonicalPackage
{
  if manifest.formatVersion == LedgerPortablePackageFormat.version,
    manifest.formatFingerprint == LedgerPortablePackageFormat.fingerprint
  {
    return try decodeCurrentPackage(data, manifest: manifest)
  }
  if manifest.formatVersion == LedgerPortablePackageFormat.legacyV10SchemaVersion,
    manifest.formatFingerprint == LedgerPortablePackageFormat.legacyV10SchemaFingerprint
  {
    return try decodeLegacyV10Package(data, manifest: manifest)
  }
  throw LedgerApplication.Error.invalidCommand
}

private func decodeCurrentPackage(_ data: Data, manifest: LedgerExportManifest) throws
  -> LedgerCanonicalPackage
{
  try decodePackageShape(
    data, manifest: manifest, versionKey: "formatVersion", fingerprintKey: "formatFingerprint")
}

private func decodeLegacyV10Package(_ data: Data, manifest: LedgerExportManifest) throws
  -> LedgerCanonicalPackage
{
  try decodePackageShape(
    data, manifest: manifest, versionKey: "schemaVersion", fingerprintKey: "schemaFingerprint")
}

private func decodePackageShape(
  _ data: Data, manifest: LedgerExportManifest, versionKey: String, fingerprintKey: String
) throws -> LedgerCanonicalPackage {
  guard hasOnlyUniqueJSONKeys(data),
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  else {
    throw LedgerApplication.Error.invalidCommand
  }
  func exactKeys(_ row: [String: Any], _ keys: Set<String>) throws {
    guard Set(row.keys) == keys else { throw LedgerApplication.Error.invalidCommand }
  }
  func maps(_ key: String) throws -> [[String: Any]] {
    guard let rows = object[key] as? [[String: Any]] else {
      throw LedgerApplication.Error.invalidCommand
    }
    return rows
  }
  func string(_ row: [String: Any], _ key: String) throws -> String {
    guard let value = row[key] as? String else { throw LedgerApplication.Error.invalidCommand }
    return value
  }
  func optionalString(_ row: [String: Any], _ key: String) throws -> String? {
    guard let value = row[key] else { throw LedgerApplication.Error.invalidCommand }
    if value is NSNull { return nil }
    guard let value = value as? String else { throw LedgerApplication.Error.invalidCommand }
    return value
  }
  func dictionaries(_ row: [String: Any], _ key: String) throws -> [[String: Any]] {
    guard let values = row[key] as? [[String: Any]] else {
      throw LedgerApplication.Error.invalidCommand
    }
    return values
  }
  func boolean(_ row: [String: Any], _ key: String) throws -> Bool {
    guard let number = row[key] as? NSNumber,
      CFGetTypeID(number) == CFBooleanGetTypeID()
    else { throw LedgerApplication.Error.invalidCommand }
    return number.boolValue
  }
  func value(_ row: [String: Any], _ key: String) throws -> Any {
    guard let value = row[key], !(value is NSNull) else {
      throw LedgerApplication.Error.invalidCommand
    }
    return value
  }
  func requiredEnum<T: RawRepresentable>(_ raw: String, as _: T.Type) throws -> T
  where T.RawValue == String {
    guard let value = T(rawValue: raw) else { throw LedgerApplication.Error.invalidCommand }
    return value
  }
  try exactKeys(
    object,
    [
      versionKey, fingerprintKey, "accounts", "categories", "revisions", "links",
      "recurrenceRules", "budgets", "installmentPlans", "preservedSource",
    ])
  guard try jsonInt(object, versionKey) == manifest.formatVersion,
    try string(object, fingerprintKey) == manifest.formatFingerprint
  else { throw LedgerApplication.Error.invalidCommand }
  let accounts = try maps("accounts").map { row in
    try exactKeys(
      row, ["id", "name", "currencyUnit", "originID", "originLabel", "lifecycle"])
    return try LedgerAccount(
      id: string(row, "id"), name: string(row, "name"),
      currencyUnit: string(row, "currencyUnit"),
      origin: LedgerOrigin(id: string(row, "originID"), label: string(row, "originLabel")),
      lifecycle: try requiredEnum(string(row, "lifecycle"), as: LedgerLifecycleState.self))
  }
  let categories = try maps("categories").map { row in
    try exactKeys(
      row, ["id", "name", "kind", "originID", "originLabel", "lifecycle"])
    return try LedgerCategory(
      id: string(row, "id"), name: string(row, "name"),
      kind: try requiredEnum(string(row, "kind"), as: LedgerCategoryKind.self),
      origin: LedgerOrigin(id: string(row, "originID"), label: string(row, "originLabel")),
      lifecycle: try requiredEnum(string(row, "lifecycle"), as: LedgerLifecycleState.self))
  }
  var revisions: [LedgerTransactionRevision] = []
  for row in try maps("revisions") {
    try exactKeys(
      row,
      [
        "id", "transactionID", "revision", "predecessorID", "lifecycle", "createdAt", "kind",
        "categoryID", "note", "roundingPolicy", "originID", "originLabel", "occurredAt",
        "effects", "literals",
      ])
    let origin = try LedgerOrigin(
      id: string(row, "originID"), label: string(row, "originLabel"))
    let occurredObject = try value(row, "occurredAt")
    let occurredData = try JSONSerialization.data(
      withJSONObject: occurredObject, options: [.sortedKeys])
    let occurred = try JSONDecoder().decode(SourceTemporal.self, from: occurredData)
    let canonicalOccurredData = try JSONSerialization.data(
      withJSONObject: JSONSerialization.jsonObject(with: JSONEncoder().encode(occurred)),
      options: [.sortedKeys])
    guard occurredData == canonicalOccurredData else {
      throw LedgerApplication.Error.invalidCommand
    }
    let effects = try dictionaries(row, "effects").map {
      try exactKeys($0, ["accountID", "direction", "amount", "unit"])
      return try LedgerTransactionEffect(
        accountID: string($0, "accountID"),
        direction: try requiredEnum(string($0, "direction"), as: LedgerEffectDirection.self),
        amount: CurrencyAmount(
          unitCode: string($0, "unit"), amount: ExactDecimal(string($0, "amount"))))
    }
    let literals = try dictionaries(row, "literals").map {
      try exactKeys($0, ["field", "literal"])
      return try LedgerSourceLiteral(
        field: string($0, "field"), literal: string($0, "literal"))
    }
    let draft = try LedgerTransactionDraft(
      effects: effects, categoryID: optionalString(row, "categoryID"),
      kind: try requiredEnum(string(row, "kind"), as: LedgerTransactionKind.self),
      occurredAt: occurred, note: optionalString(row, "note"),
      roundingPolicy: try optionalString(row, "roundingPolicy").map {
        try requiredEnum($0, as: RoundingPolicy.self)
      }, sourceLiterals: literals,
      origin: origin)
    revisions.append(
      try LedgerTransactionRevision(
        id: string(row, "id"), transactionID: string(row, "transactionID"),
        revision: jsonInt(row, "revision"),
        predecessorID: optionalString(row, "predecessorID"),
        draft: draft,
        lifecycle: try requiredEnum(string(row, "lifecycle"), as: LedgerLifecycleState.self),
        createdAt: UTCInstant(epochMilliseconds: try jsonInt64(row, "createdAt"))))
  }
  let links = try maps("links").map {
    try exactKeys($0, ["id", "from", "to", "kind"])
    return try LedgerTransactionLink(
      id: string($0, "id"), fromTransactionID: string($0, "from"),
      toTransactionID: string($0, "to"),
      kind: try requiredEnum(string($0, "kind"), as: LedgerTransactionLinkKind.self))
  }
  let recurrenceRules = try maps("recurrenceRules").map { row -> LedgerRecurrenceRule in
    try exactKeys(
      row,
      [
        "id", "originID", "originLabel", "accountID", "categoryID", "kind", "amount", "unit",
        "frequency", "interval", "dayOfMonth", "timezoneKind", "timezoneValue", "startYear",
        "startMonth", "startDay", "untilYear", "untilMonth", "untilDay", "paused", "skipped",
        "lifecycle",
      ])
    let origin = try LedgerOrigin(
      id: string(row, "originID"), label: string(row, "originLabel"))
    let start = try SourceLocalDate(
      year: jsonInt(row, "startYear"), month: jsonInt(row, "startMonth"),
      day: jsonInt(row, "startDay"))
    let untilKeys = ["untilYear", "untilMonth", "untilDay"]
    let untilFields = untilKeys.filter { row[$0] != nil && !(row[$0] is NSNull) }
    guard untilFields.isEmpty || untilFields.count == untilKeys.count else {
      throw LedgerApplication.Error.invalidCommand
    }
    let until: SourceLocalDate?
    if !untilFields.isEmpty {
      until = try SourceLocalDate(
        year: jsonInt(row, "untilYear"), month: jsonInt(row, "untilMonth"),
        day: jsonInt(row, "untilDay"))
    } else {
      until = nil
    }
    let skipped = try dictionaries(row, "skipped").map {
      try exactKeys($0, ["year", "month", "day"])
      return try SourceLocalDate(
        year: jsonInt($0, "year"), month: jsonInt($0, "month"), day: jsonInt($0, "day"))
    }
    let zone: SourceTimeZone
    switch try string(row, "timezoneKind") {
    case "iana":
      zone = try SourceTimeZone(ianaIdentifier: string(row, "timezoneValue"))
    case "fixed":
      guard let offset = Int(try string(row, "timezoneValue")) else {
        throw LedgerApplication.Error.invalidCommand
      }
      zone = try SourceTimeZone(fixedOffsetSeconds: offset)
    default:
      throw LedgerApplication.Error.invalidCommand
    }
    return try LedgerRecurrenceRule(
      id: string(row, "id"), origin: origin, accountID: string(row, "accountID"),
      categoryID: optionalString(row, "categoryID"),
      kind: try requiredEnum(string(row, "kind"), as: LedgerTransactionKind.self),
      amount: CurrencyAmount(
        unitCode: string(row, "unit"), amount: ExactDecimal(string(row, "amount"))),
      frequency: try requiredEnum(
        string(row, "frequency"), as: LedgerRecurrenceFrequency.self),
      interval: jsonInt(row, "interval"),
      dayOfMonth: try optionalJSONInt(row, "dayOfMonth"),
      timeZone: zone, start: start, until: until,
      paused: boolean(row, "paused"), skippedDates: skipped,
      lifecycle: try requiredEnum(string(row, "lifecycle"), as: LedgerLifecycleState.self))
  }
  let budgets = try maps("budgets").map { row in
    try exactKeys(
      row,
      [
        "id", "originID", "originLabel", "name", "categoryID", "amount", "unit", "period",
        "rollover", "startYear", "startMonth", "startDay", "lifecycle",
      ])
    return try LedgerBudget(
      id: string(row, "id"),
      origin: LedgerOrigin(
        id: string(row, "originID"), label: string(row, "originLabel")),
      name: string(row, "name"), categoryID: string(row, "categoryID"),
      amount: CurrencyAmount(
        unitCode: string(row, "unit"), amount: ExactDecimal(string(row, "amount"))),
      period: try requiredEnum(string(row, "period"), as: LedgerBudget.Period.self),
      rollover: boolean(row, "rollover"),
      start: SourceLocalDate(
        year: jsonInt(row, "startYear"), month: jsonInt(row, "startMonth"),
        day: jsonInt(row, "startDay")),
      lifecycle: try requiredEnum(string(row, "lifecycle"), as: LedgerLifecycleState.self))
  }
  let installmentPlans = try maps("installmentPlans").map { row in
    try exactKeys(
      row,
      [
        "id", "originID", "originLabel", "accountID", "categoryID", "principal", "unit",
        "occurrenceCount", "completedCount", "lifecycle",
      ])
    return try LedgerInstallmentPlan(
      id: string(row, "id"),
      origin: LedgerOrigin(
        id: string(row, "originID"), label: string(row, "originLabel")),
      accountID: string(row, "accountID"), categoryID: optionalString(row, "categoryID"),
      principal: CurrencyAmount(
        unitCode: string(row, "unit"), amount: ExactDecimal(string(row, "principal"))),
      occurrenceCount: jsonInt(row, "occurrenceCount"),
      completedCount: jsonInt(row, "completedCount"),
      lifecycle: try requiredEnum(
        string(row, "lifecycle"), as: LedgerInstallmentPlan.Lifecycle.self))
  }
  let preservedSource = try maps("preservedSource").map { row -> LedgerPreservedSourceRecord in
    try exactKeys(
      row, ["table", "recordKey", "columnName", "storageClass", "payload", "reasonCode"])
    guard let payload = Data(base64Encoded: try string(row, "payload")) else {
      throw LedgerApplication.Error.invalidCommand
    }
    return LedgerPreservedSourceRecord(
      table: try string(row, "table"), recordKey: try string(row, "recordKey"),
      columnName: try string(row, "columnName"), storageClass: try string(row, "storageClass"),
      payload: payload, reasonCode: try string(row, "reasonCode"))
  }
  return LedgerCanonicalPackage(
    formatVersion: LedgerPortablePackageFormat.version,
    formatFingerprint: LedgerPortablePackageFormat.fingerprint,
    accounts: accounts, categories: categories, revisions: revisions, links: links,
    recurrenceRules: recurrenceRules, budgets: budgets, installmentPlans: installmentPlans,
    preservedSource: preservedSource)
}

private struct JSONKeyScope {
  var keys: Set<String>?
}

private func hasOnlyUniqueJSONKeys(_ data: Data) -> Bool {
  guard data.count <= maximumPortablePackageBytes else { return false }
  var scopes: [JSONKeyScope] = []
  var stringBytes: [UInt8] = []
  var structuralTokens = 0
  var isInsideString = false
  var isEscaped = false
  var index = data.startIndex
  while index < data.endIndex {
    let byte = data[index]
    if isInsideString {
      if isEscaped {
        stringBytes.append(byte)
        isEscaped = false
      } else if byte == 0x5C {
        stringBytes.append(byte)
        isEscaped = true
      } else if byte == 0x22 {
        isInsideString = false
        var next = data.index(after: index)
        while next < data.endIndex, [0x20, 0x09, 0x0A, 0x0D].contains(data[next]) {
          next = data.index(after: next)
        }
        if next < data.endIndex, data[next] == 0x3A {
          guard !scopes.isEmpty, var keys = scopes[scopes.count - 1].keys,
            let key = try? JSONDecoder().decode(
              String.self, from: Data([0x22] + stringBytes + [0x22])),
            keys.insert(key).inserted
          else { return false }
          scopes[scopes.count - 1].keys = keys
        }
      } else {
        stringBytes.append(byte)
      }
      if stringBytes.count > maximumPortableJSONStringBytes { return false }
    } else {
      switch byte {
      case 0x22:
        isInsideString = true
        stringBytes = []
      case 0x7B:
        scopes.append(JSONKeyScope(keys: []))
        structuralTokens += 1
      case 0x5B:
        scopes.append(JSONKeyScope(keys: nil))
        structuralTokens += 1
      case 0x2C:
        structuralTokens += 1
      case 0x7D:
        guard scopes.last?.keys != nil else { return false }
        scopes.removeLast()
      case 0x5D:
        guard !scopes.isEmpty, scopes.last?.keys == nil else { return false }
        scopes.removeLast()
      default:
        break
      }
      if scopes.count > maximumPortableJSONNesting
        || structuralTokens > maximumPortableJSONStructuralTokens
      {
        return false
      }
    }
    index = data.index(after: index)
  }
  return scopes.isEmpty && !isInsideString && !isEscaped
}

private func jsonInt(_ row: [String: Any], _ key: String) throws -> Int {
  guard let value = Int(try jsonIntegerLiteral(row, key)) else {
    throw LedgerApplication.Error.invalidCommand
  }
  return value
}

private func jsonInt64(_ row: [String: Any], _ key: String) throws -> Int64 {
  guard let value = Int64(try jsonIntegerLiteral(row, key)) else {
    throw LedgerApplication.Error.invalidCommand
  }
  return value
}

private func optionalJSONInt(_ row: [String: Any], _ key: String) throws -> Int? {
  guard let value = row[key] else { throw LedgerApplication.Error.invalidCommand }
  if value is NSNull { return nil }
  return try jsonInt(row, key)
}

private func hasUnsupportedPortableProvenance(_ snapshot: LedgerStore.LedgerReadSnapshot) -> Bool {
  let origins =
    snapshot.accounts.map(\.origin) + snapshot.categories.map(\.origin)
    + snapshot.revisionHistory.map(\.draft.origin) + snapshot.recurrenceRules.map(\.origin)
    + snapshot.budgets.map(\.origin) + snapshot.installmentPlans.map(\.origin)
  let importedOriginID = String(repeating: "e", count: 64)
  return origins.contains {
    $0.provenanceID != nil || $0.id == importedOriginID || $0.label == LedgerOrigin.importedLabel
  }
    || snapshot.revisionHistory.contains { revision in
      revision.draft.sourceLiterals.contains {
        $0.provenanceID != nil || $0.field == "import.eventID"
      }
    }
}

private func jsonIntegerLiteral(_ row: [String: Any], _ key: String) throws -> String {
  guard let number = row[key] as? NSNumber,
    CFGetTypeID(number) != CFBooleanGetTypeID()
  else { throw LedgerApplication.Error.invalidCommand }
  return number.stringValue
}

private func lastDay(year: Int, month: Int) -> Int {
  switch month {
  case 1, 3, 5, 7, 8, 10, 12:
    return 31
  case 4, 6, 9, 11:
    return 30
  case 2:
    let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    return leap ? 29 : 28
  default:
    return 28
  }
}
