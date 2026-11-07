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
  /// The money-out leg of a transfer. Its partner is the type-4 row with the same group id.
  public static let transferDebitType = "3"
  /// The money-in leg of a transfer.
  public static let transferCreditType = "4"
  /// Group id shared by the two legs of one transfer. Observed on the 2026-11-01 backup: every
  /// group holds exactly one type-3 and one type-4 row.
  public static let transferGroupAliases = ["txUidTrans", "TX_UID_TRANS", "ZTXUIDTRANS"]

  // MARK: Debit cards (#207)

  public static let assetGroupTables: Set<String> = ["ASSETGROUP", "ZASSETGROUP"]
  public static let groupUIDAliases = ["groupUid", "GROUP_UID", "ZGROUPUID"]
  public static let groupTypeAliases = ["TYPE", "ZTYPE"]
  public static let cardAssetAliases = ["cardAssetUid", "CARD_ASSET_UID", "ZCARDASSETUID"]
  /// `ASSETGROUP.TYPE` of the Debit Card group.
  public static let debitCardGroupType = "3"

  /// Money Manager keeps no balance for a Debit Card account (its group's `TYPE` is 3): its
  /// rows move the account named in its `cardAssetUid`. A credit card (`TYPE` 2) also names a
  /// paying account there, but its rows stay on the card. The import, the balance receipt and
  /// ledger replay all read cards through this one rule.
  public struct DebitCards: Equatable, Sendable {
    /// Every account in the Debit Card group.
    public let cards: Set<String>
    /// For each debit card that names another existing account: that account.
    public let payingAccountByCard: [String: String]

    /// `accounts` and `groups` are each record's mapping literals by column name.
    public init(accounts: [[String: String]], groups: [[String: String]]) {
      // A group uid listed twice with different types proves nothing.
      var typeByGroup: [String: String?] = [:]
      for group in groups {
        guard let uid = aliased(group, uidAliases), !uid.isEmpty,
          let type = aliased(group, groupTypeAliases)
        else { continue }
        if let seen = typeByGroup[uid], seen != type {
          typeByGroup[uid] = .some(nil)
        } else {
          typeByGroup[uid] = type
        }
      }
      var accountByUID: [String: [String: String]] = [:]
      for account in accounts {
        guard let uid = aliased(account, uidAliases), !uid.isEmpty else { continue }
        accountByUID[uid] = accountByUID[uid] ?? account
      }
      var cards: Set<String> = []
      var paying: [String: String] = [:]
      for (uid, account) in accountByUID {
        guard let group = aliased(account, groupUIDAliases),
          typeByGroup[group] == .some(debitCardGroupType)
        else { continue }
        cards.insert(uid)
        if let payer = aliased(account, cardAssetAliases), !payer.isEmpty, payer != uid,
          accountByUID[payer] != nil
        {
          paying[uid] = payer
        }
      }
      self.cards = cards
      self.payingAccountByCard = paying
    }

    /// The account a row booked on `accountUID` moves.
    public func movedAccount(_ accountUID: String) -> String {
      payingAccountByCard[accountUID] ?? accountUID
    }
  }

  /// The retained `ASSETS` and `ASSETGROUP` fields of one import, which replay reads to check a
  /// debit-card entry's account proof.
  public struct RetainedAccounts: Sendable {
    let fieldsByRecord: [String: [String: String]]
    public let debitCards: DebitCards

    public init(fields: [RetainedSidecar]) {
      var records: [String: [String: String]] = [:]
      var groups: [String: [String: String]] = [:]
      for field in fields {
        let table = field.locator.table
        guard let column = field.locator.columnName,
          accountTables.contains(table) || assetGroupTables.contains(table),
          let literal = mappingLiteral(storageClass: field.storageClass, payload: field.payload)
        else { continue }
        let key = Self.key(table, field.locator.recordKey)
        if accountTables.contains(table) {
          records[key, default: [:]][column] = literal
        } else {
          groups[key, default: [:]][column] = literal
        }
      }
      fieldsByRecord = records
      debitCards = DebitCards(
        accounts: records.keys.sorted().map { records[$0]! },
        groups: groups.keys.sorted().map { groups[$0]! })
    }

    static func key(_ table: String, _ recordKey: String) -> String { table + "\u{0}" + recordKey }

    func fields(_ locator: SourceLocator) -> [String: String]? {
      fieldsByRecord[Self.key(locator.table, locator.recordKey)]
    }
  }

  public static func isTransferType(_ type: String) -> Bool {
    type == transferDebitType || type == transferCreditType
  }

  /// Deterministic id of a transfer pair, so a reimport writes the same row.
  public static func transferID(debitEventID: String, creditEventID: String) -> String {
    CanonicalReceiptDigest.hash(["mm-transfer", debitEventID, creditEventID])
  }

  /// A transfer leg's commitments live on the shared transfer revision, so each field name is
  /// qualified by the leg. Other events keep the plain field name.
  public static func commitmentField(_ field: String, kind: CanonicalEventKind) -> String {
    switch kind {
    case .transferDebit: field + ".debit"
    case .transferCredit: field + ".credit"
    default: field
    }
  }

  /// First ordinal of an event's five commitments on its revision. The store's own literals sit
  /// before them: `import.eventID` at 0, or `import.eventID.debit/.credit` at 0 and 1.
  public static func commitmentOrdinalBase(kind: CanonicalEventKind) -> Int {
    switch kind {
    case .transferDebit: 2
    case .transferCredit: 7
    default: 1
    }
  }

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

  /// `accounts` is needed only for an entry made with a debit card, whose account binding
  /// names the card's `cardAssetUid` instead of the row's own `assetUid` (#207).
  public static func validateReplay(
    profileID: String, adapterVersion: String, event: CanonicalEconomicEvent,
    fields: [RetainedField], sidecars: [RetainedSidecar] = [],
    accounts: RetainedAccounts? = nil, temporalCommitment: String
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
      accountProofHolds(account, sidecars: sidecars, accounts: accounts),
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
        || (kindLiteral == balanceDecreaseType && event.kind == .adjustmentDebit)
        || (kindLiteral == transferDebitType && event.kind == .transferDebit)
        || (kindLiteral == transferCreditType && event.kind == .transferCredit),
      occurredMatches(occurredLiteral, event.occurredAt),
      observedDay(wdateLiteral) == event.occurredAt.localDateTime.date
    else { return .invalid }
    return .valid
  }

  /// Two forms prove an event's account. The row's own `assetUid` (every entry before #207,
  /// and every entry not made with a debit card). Or, for a debit card, the card's
  /// `ASSETS.cardAssetUid`: the row's `assetUid` must name that card, and the card must sit in
  /// the Debit Card group and name another existing account.
  static func accountProofHolds(
    _ account: RetainedField, sidecars: [RetainedSidecar], accounts: RetainedAccounts?
  ) -> Bool {
    let column = account.locator.columnName ?? ""
    if transactionTables.contains(account.locator.table) {
      return assetAliases.contains(column)
    }
    guard accountTables.contains(account.locator.table), cardAssetAliases.contains(column),
      let accounts, let card = accounts.fields(account.locator),
      let cardUID = aliased(card, uidAliases),
      let payer = mappingLiteral(storageClass: account.storageClass, payload: account.payload),
      card[column] == payer, accounts.debitCards.payingAccountByCard[cardUID] == payer
    else { return false }
    let rowAccounts = sidecars.filter {
      transactionTables.contains($0.locator.table)
        && assetAliases.contains($0.locator.columnName ?? "")
    }
    guard rowAccounts.count == 1,
      let rowAccount = mappingLiteral(
        storageClass: rowAccounts[0].storageClass, payload: rowAccounts[0].payload)
    else { return false }
    return rowAccount == cardUID
  }

  /// The canonical temporal for a ZDATE epoch: ZDATE is the UTC instant, and the local wall
  /// time is that instant in `zone`.
  public static func temporal(zdateEpochMilliseconds milliseconds: Int64, in zone: SourceTimeZone)
    -> SourceTemporal?
  {
    let offset: Int
    if let fixed = zone.fixedOffsetSeconds {
      offset = fixed
    } else if let identifier = zone.ianaIdentifier, let foundation = TimeZone(identifier: identifier)
    {
      let (seconds, _) = milliseconds.dividedReportingOverflow(by: 1_000)
      offset = foundation.secondsFromGMT(for: Date(timeIntervalSince1970: Double(seconds)))
    } else {
      return nil
    }
    let (shifted, overflow) = milliseconds.addingReportingOverflow(Int64(offset) * 1_000)
    guard !overflow else { return nil }
    let civil = GregorianCivil.components(epochMilliseconds: shifted)
    guard let date = try? SourceLocalDate(year: civil.year, month: civil.month, day: civil.day),
      let local = try? SourceLocalDateTime(
        date: date, hour: civil.hour, minute: civil.minute, second: civil.second,
        millisecond: civil.millisecond)
    else { return nil }
    return try? SourceTemporal(
      instant: UTCInstant(epochMilliseconds: milliseconds), localDateTime: local, timeZone: zone,
      precision: .millisecond, resolvedOffsetSeconds: offset)
  }

  /// True when a persisted event's time is what ZDATE says. Current imports read ZDATE as the
  /// UTC instant. Ledgers written by earlier adapter builds read it as a local wall-clock
  /// epoch; they stay valid so an upgrade never invalidates an existing ledger.
  public static func occurredMatches(_ zdateLiteral: String, _ occurredAt: SourceTemporal) -> Bool {
    if let milliseconds = Int64(zdateLiteral),
      occurredAt.instant.epochMilliseconds == milliseconds,
      temporal(zdateEpochMilliseconds: milliseconds, in: occurredAt.timeZone)?.localDateTime
        == occurredAt.localDateTime
    {
      return true
    }
    guard let legacyLocal = observedLocalDateTime(zdateLiteral),
      legacyLocal == occurredAt.localDateTime
    else { return false }
    // The instant must be the legacy wall time resolved in the event's zone, as the earlier
    // build wrote it. Only an IANA zone this OS no longer knows skips the check; SourceTemporal
    // itself still guarantees instant + offset == wall time.
    if let identifier = occurredAt.timeZone.ianaIdentifier, TimeZone(identifier: identifier) == nil {
      return true
    }
    return (try? SourceTemporal(
      resolving: legacyLocal, in: occurredAt.timeZone,
      precision: occurredAt.precision, ambiguityPolicy: .reject)) == occurredAt
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
