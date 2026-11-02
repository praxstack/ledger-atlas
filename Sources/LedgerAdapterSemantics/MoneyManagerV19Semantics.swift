import Foundation
import LedgerCore

/// Versioned, adapter-owned replay proof for the admitted Money Manager v19 profiles.
/// LedgerStore selects this by persisted profile/version but never owns vendor vocabulary.
public enum MoneyManagerV19Semantics {
  public static let adapterVersion = "money-manager-android-v19-adapter-v1"
  public static let temporalCommitmentField = "import.v19Commitment"
  public static let temporalAnchorField = "import.v19TemporalAnchor"
  public static let receiptGenerationField = "import.v19ReceiptGeneration"
  public static let sourceSubjectSetField = "import.v19SourceSubjectSet"
  public static let sourceTimeZoneField = "import.v19SourceTimeZone"
  public static let currentReceiptGenerationLiteral = "current"
  public static let legacyReceiptGenerationLiteral = "legacy"
  public static let currentReceiptGeneration = "money-manager-v19-receipt-v1"
  public static let admittedProfileIDs: Set<String> = [
    "realbyte-android-v19-synthetic-text-subset-v1", "realbyte-android-sqlite-v19-observed",
    "realbyte-android-sqlite-v19-family", "realbyte-ios-sqlite-v19-family",
    "realbyte-macos-sqlite-v19-family",
  ]

  public static let accountTables: Set<String> = ["ASSETS", "ZASSETS"]
  public static let categoryTables: Set<String> = ["ZCATEGORY", "CATEGORY"]
  public static let currencyTables: Set<String> = ["CURRENCY", "ZCURRENCY"]
  public static let transactionTables: Set<String> = ["INOUTCOME", "ZINOUTCOME"]
  public static let recognizedTables = accountTables.union(categoryTables).union(currencyTables)
    .union(transactionTables)
  public static let uidAliases = ["uid", "UID", "ZUID", "Z_PK"]
  public static let isoAliases = ["ISO", "ZISO", "CODE"]
  public static let nameAliases = ["name", "NAME", "ZNAME", "NIC_NAME"]
  public static let parentCategoryAliases = [
    "pUid", "PUID", "ZPUID", "parentUid", "PARENT_UID", "ZPARENTUID",
    "parentCategoryUid", "PARENT_CATEGORY_UID", "ZPARENTCATEGORYUID",
  ]
  public static let assetAliases = ["assetUid", "ASSET_UID", "ZASSETUID", "ZASSET"]
  public static let currencyUIDAliases = [
    "currencyUid", "CURRENCY_UID", "ZCURRENCYUID", "ZCURRENCY",
  ]
  public static let categoryAliases = ["ctgUid", "CTG_UID", "ZCTGUID", "ZCATEGORY"]
  public static let doTypeAliases = ["DO_TYPE", "ZDOTYPE", "DOTYPE"]
  public static let amountAliases = ["ZMONEY", "AMOUNT", "ZAMOUNT"]
  public static let wdateAliases = ["WDATE", "ZWDATE"]
  public static let zdateAliases = ["ZDATE"]
  /// Built-in category the app writes when the user edits an account balance. It has no
  /// category row. Owner-described and data-backed on 2026-11-01; see
  /// docs/compatibility/money-manager-v19-schema-contract.md.
  public static let balanceEditCategoryUID = "-4"
  /// A balance increase the user chose not to record as income ("No" on the app's prompt).
  /// It moves the balance but is left out of income totals, so it maps to an adjustment.
  /// Admitted only together with `balanceEditCategoryUID`. Proven on the 2026-11-02 test backup:
  /// account balances only reconcile when type 7 adds money.
  public static let balanceIncreaseType = "7"
  /// A balance decrease the user chose not to record as expense ("No" on the app's prompt).
  /// It takes money out of the account but is left out of expense totals, so it maps to a
  /// decreasing adjustment. Admitted only together with `balanceEditCategoryUID`. Proven on the
  /// 2026-11-02 test backup: account balances only reconcile when type 8 removes money.
  public static let balanceDecreaseType = "8"

  public struct RetainedField: Sendable {
    public let semantic: CanonicalEventSourceSemantic
    public let locator: SourceLocator
    public let storageClass: CanonicalFieldStorageClass
    public let payload: Data

    public init(
      semantic: CanonicalEventSourceSemantic, locator: SourceLocator,
      storageClass: CanonicalFieldStorageClass, payload: Data
    ) {
      self.semantic = semantic
      self.locator = locator
      self.storageClass = storageClass
      self.payload = payload
    }
  }

  public struct RetainedSidecar: Sendable {
    public let locator: SourceLocator
    public let storageClass: CanonicalFieldStorageClass
    public let payload: Data
    public init(locator: SourceLocator, storageClass: CanonicalFieldStorageClass, payload: Data) {
      self.locator = locator
      self.storageClass = storageClass
      self.payload = payload
    }
  }

  public enum ReplayResult: Equatable, Sendable { case notAdmitted, valid, invalid }

  public enum ReceiptGeneration: Equatable, Sendable {
    case legacy
    case current
  }

  public static func receiptIntegrityHash(
    envelope: [String], eventSetHash: String, preservationHash: String,
    generation: ReceiptGeneration
  ) -> String {
    let prefix: [String]
    switch generation {
    case .legacy:
      prefix = ["ledger-atlas/canonical-receipt-integrity/v6"]
    case .current:
      prefix = [
        "ledger-atlas/canonical-receipt-integrity/v7", currentReceiptGeneration,
      ]
    }
    return CanonicalReceiptDigest.hash(prefix + envelope + [eventSetHash, preservationHash])
  }

  public static func authenticatedReceiptGeneration(
    storedIntegrityHash: String, envelope: [String], eventSetHash: String,
    preservationHash: String
  ) -> ReceiptGeneration? {
    for generation in [ReceiptGeneration.current, .legacy]
    where receiptIntegrityHash(
      envelope: envelope, eventSetHash: eventSetHash, preservationHash: preservationHash,
      generation: generation) == storedIntegrityHash
    {
      return generation
    }
    return nil
  }

  public static func temporalCommitment(_ temporal: SourceTemporal) -> String {
    let zoneKind = temporal.timeZone.ianaIdentifier == nil ? "fixed" : "iana"
    let zoneValue =
      temporal.timeZone.ianaIdentifier
      ?? String(temporal.timeZone.fixedOffsetSeconds!)
    return CanonicalReceiptDigest.hash([
      "ledger-atlas/money-manager-v19-source-temporal/v1", zoneKind, zoneValue,
      String(temporal.instant.epochMilliseconds), String(temporal.resolvedOffsetSeconds),
    ])
  }

  /// Stable source-field cardinality proof for a mapped vendor record. The value is derived
  /// from the authenticated staging graph, not from mutable canonical sidecar rows.
  public static func sourceSubjectSetCommitment(
    sourceRecordID: String, fieldIDs: [String]
  ) -> String {
    CanonicalReceiptDigest.hash(
      ["ledger-atlas/money-manager-v19-source-subject-set/v1", sourceRecordID]
        + fieldIDs.sorted())
  }

  public static func sourceTimeZoneLiteral(_ timeZone: SourceTimeZone) -> String {
    timeZone.ianaIdentifier.map { "iana:\($0)" }
      ?? "fixed:\(timeZone.fixedOffsetSeconds!)"
  }

  public static func validateReplay(
    profileID: String, adapterVersion: String, event: CanonicalEconomicEvent,
    fields: [RetainedField], sidecars: [RetainedSidecar] = [],
    temporalCommitment: String
  ) -> ReplayResult {
    guard admittedProfileIDs.contains(profileID) else { return .notAdmitted }
    guard adapterVersion == self.adapterVersion else { return .invalid }
    guard fields.count == CanonicalEventSourceSemantic.allCases.count,
      Set(fields.map(\.semantic)).count == fields.count,
      let amount = field(.amount, fields), let currency = field(.currency, fields),
      let occurredAt = field(.occurredAt, fields), let account = field(.account, fields),
      let kind = field(.kind, fields),
      let wdate = sidecars.first(where: {
        transactionTables.contains($0.locator.table)
          && wdateAliases.contains($0.locator.columnName ?? "")
      }),
      transactionTables.contains(amount.locator.table),
      amountAliases.contains(amount.locator.columnName ?? ""),
      transactionTables.contains(occurredAt.locator.table),
      zdateAliases.contains(occurredAt.locator.columnName ?? ""),
      transactionTables.contains(account.locator.table),
      assetAliases.contains(account.locator.columnName ?? ""),
      transactionTables.contains(kind.locator.table),
      doTypeAliases.contains(kind.locator.columnName ?? ""),
      currencyTables.contains(currency.locator.table),
      isoAliases.contains(currency.locator.columnName ?? "")
    else { return .invalid }
    guard temporalCommitment == self.temporalCommitment(event.occurredAt),
      let amountLiteral = mappingLiteral(
        storageClass: amount.storageClass, payload: amount.payload),
      let currencyLiteral = mappingLiteral(
        storageClass: currency.storageClass, payload: currency.payload),
      let accountLiteral = mappingLiteral(
        storageClass: account.storageClass, payload: account.payload),
      let kindLiteral = mappingLiteral(storageClass: kind.storageClass, payload: kind.payload),
      let occurredLiteral = mappingLiteral(
        storageClass: occurredAt.storageClass, payload: occurredAt.payload),
      let wdateLiteral = mappingLiteral(storageClass: wdate.storageClass, payload: wdate.payload),
      amountLiteral == event.amount.amount.rawLiteral,
      currencyLiteral == event.amount.unitCode,
      event.accountID
        == (try? StableCanonicalID.account(profileID: profileID, sourceAccountID: accountLiteral)),
      (kindLiteral == "0" && event.kind == .income)
        || (kindLiteral == "1" && event.kind == .expense)
        || (kindLiteral == balanceIncreaseType && event.kind == .adjustment)
        || (kindLiteral == balanceDecreaseType && event.kind == .adjustmentDebit),
      let observedLocal = observedLocalDateTime(occurredLiteral),
      observedLocal == event.occurredAt.localDateTime,
      event.occurredAt.timeZone.fixedOffsetSeconds == nil
        || (try? SourceTemporal(
          resolving: observedLocal, in: event.occurredAt.timeZone,
          precision: event.occurredAt.precision, ambiguityPolicy: .reject)) == event.occurredAt,
      observedDay(wdateLiteral) == event.occurredAt.localDateTime.date
    else { return .invalid }
    return .valid
  }

  public static func mappingLiteral(storageClass: CanonicalFieldStorageClass, payload: Data)
    -> String?
  {
    switch storageClass {
    case .text: return String(data: payload, encoding: .utf8)
    case .integer:
      guard payload.count == 8 else { return nil }
      return String(Int64(bitPattern: payload.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }))
    case .null, .real, .blob: return nil
    }
  }

  public static func mappingLiteral(
    storageClass: CanonicalFieldStorageClass, payload: Data, value: String
  ) -> String? {
    if storageClass == .integer {
      return mappingLiteral(storageClass: storageClass, payload: payload)
    }
    return !value.isEmpty ? value : mappingLiteral(storageClass: storageClass, payload: payload)
  }

  public static func mappingLiteral(storageClass: String, payload: Data) -> String? {
    guard let storageClass = CanonicalFieldStorageClass(rawValue: storageClass) else { return nil }
    return mappingLiteral(storageClass: storageClass, payload: payload)
  }

  public static func aliased<T>(_ values: [String: T], _ names: [String]) -> T? {
    for name in names where values[name] != nil { return values[name] }
    return nil
  }

  private static func field(
    _ semantic: CanonicalEventSourceSemantic, _ fields: [RetainedField]
  ) -> RetainedField? { fields.first { $0.semantic == semantic } }

  private static func observedLocalDateTime(_ literal: String) -> SourceLocalDateTime? {
    guard let milliseconds = Int64(literal) else { return nil }
    let civil = GregorianCivil.components(epochMilliseconds: milliseconds)
    guard let date = try? SourceLocalDate(year: civil.year, month: civil.month, day: civil.day)
    else { return nil }
    return try? SourceLocalDateTime(
      date: date, hour: civil.hour, minute: civil.minute, second: civil.second,
      millisecond: civil.millisecond)
  }

  private static func observedDay(_ literal: String) -> SourceLocalDate? {
    let parts = literal.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]),
      let day = Int(parts[2])
    else { return nil }
    return try? SourceLocalDate(year: year, month: month, day: day)
  }
}
