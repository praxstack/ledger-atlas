import Foundation

public enum LedgerCommandError: Error, Equatable, Sendable {
  case invalidTransfer
  case invalidSplit
  case invalidInstallment
  case invalidRecurrence
  /// A catch-up would create more occurrences than `LedgerSchedule.maximumOccurrences`.
  case recurrenceRangeTooLong
  case invalidBudget
  case invalidSearch
  case invalidExport
  case ledgerUnchanged
}

public struct LedgerConversion: Equatable, Sendable {
  public let sourceAmount: CurrencyAmount
  public let convertedAmount: CurrencyAmount
  public let rate: ExactDecimal
  public let rateScale: Int
  public let rounding: RoundingPolicy

  public init(
    sourceAmount: CurrencyAmount, convertedAmount: CurrencyAmount, rate: ExactDecimal,
    rateScale: Int, rounding: RoundingPolicy
  ) throws {
    guard sourceAmount.unitCode != convertedAmount.unitCode, rateScale >= 0, rateScale <= 16,
      rate.isPositive
    else { throw LedgerCommandError.invalidTransfer }
    let expected = try sourceAmount.amount.divided(by: rate, scale: convertedAmount.amount.sourceScale, rounding: rounding)
    // Keep the declared converted amount as source of truth; rate is provenance.
    _ = expected
    self.sourceAmount = sourceAmount
    self.convertedAmount = convertedAmount
    self.rate = rate
    self.rateScale = rateScale
    self.rounding = rounding
  }

  /// The rate implied by the two amounts, as `rate` is defined here (source units per converted
  /// unit), so a transfer records exactly what left and what arrived.
  public static func impliedRate(
    sourceAmount: CurrencyAmount, convertedAmount: CurrencyAmount, scale: Int
  ) throws -> ExactDecimal {
    guard sourceAmount.amount.isPositive, convertedAmount.amount.isPositive else {
      throw LedgerCommandError.invalidTransfer
    }
    return try sourceAmount.amount.divided(
      by: convertedAmount.amount, scale: scale, rounding: .halfEven)
  }

  public var literals: [LedgerSourceLiteral] {
    get throws {
      [
        try LedgerSourceLiteral(field: "conversion.rate", literal: rate.rawLiteral),
        try LedgerSourceLiteral(field: "conversion.rateScale", literal: String(rateScale)),
        try LedgerSourceLiteral(field: "conversion.rounding", literal: rounding.rawValue),
        try LedgerSourceLiteral(field: "conversion.sourceUnit", literal: sourceAmount.unitCode),
        try LedgerSourceLiteral(
          field: "conversion.sourceAmount", literal: sourceAmount.amount.rawLiteral),
        try LedgerSourceLiteral(
          field: "conversion.convertedUnit", literal: convertedAmount.unitCode),
        try LedgerSourceLiteral(
          field: "conversion.convertedAmount", literal: convertedAmount.amount.rawLiteral),
      ]
    }
  }
}

public struct LedgerSplitLine: Equatable, Sendable {
  public let id: String
  public let amount: CurrencyAmount
  public let categoryID: String
  public let description: String?
  public let displayOrder: Int

  public init(
    id: String, amount: CurrencyAmount, categoryID: String, description: String? = nil,
    displayOrder: Int = 0
  ) throws {
    let zero = try ExactDecimal("0")
    guard CanonicalIdentifier.isValid(id), CanonicalIdentifier.isValid(categoryID),
      amount.amount > zero, displayOrder >= 0,
      description.map({ LedgerValidation.text($0, maximum: 4_096) }) != false
    else { throw LedgerCommandError.invalidSplit }
    self.id = id
    self.amount = amount
    self.categoryID = categoryID
    self.description = description
    self.displayOrder = displayOrder
  }

  public init(
    id: String, amount: CurrencyAmount, categoryID: String, description: String? = nil, order: Int
  ) throws {
    try self.init(
      id: id, amount: amount, categoryID: categoryID, description: description,
      displayOrder: order)
  }
}

public struct LedgerSplitDraft: Equatable, Sendable {
  public let id: String
  public let accountID: String
  public let parentAmount: CurrencyAmount
  public let lines: [LedgerSplitLine]
  public let occurredAt: SourceTemporal
  public let note: String?
  public let origin: LedgerOrigin

  public var purchaseID: String { id }
  public var total: CurrencyAmount { parentAmount }

  public init(
    id: String, accountID: String, parentAmount: CurrencyAmount, lines: [LedgerSplitLine],
    occurredAt: SourceTemporal, note: String? = nil, origin: LedgerOrigin
  ) throws {
    let zero = try ExactDecimal("0")
    guard CanonicalIdentifier.isValid(id), CanonicalIdentifier.isValid(accountID),
      !lines.isEmpty, lines.count <= 64, parentAmount.amount > zero,
      note.map({ LedgerValidation.text($0, maximum: 4_096) }) != false,
      Set(lines.map(\.id)).count == lines.count,
      Set(lines.map(\.displayOrder)).count == lines.count,
      lines.allSatisfy({ $0.amount.unitCode == parentAmount.unitCode })
    else { throw LedgerCommandError.invalidSplit }
    var total = zero
    for line in lines { total = try total.adding(line.amount.amount) }
    guard total == parentAmount.amount else { throw LedgerCommandError.invalidSplit }
    self.id = id
    self.accountID = accountID
    self.parentAmount = parentAmount
    self.lines = lines.sorted { ($0.displayOrder, $0.id) < ($1.displayOrder, $1.id) }
    self.occurredAt = occurredAt
    self.note = note
    self.origin = origin
  }
}

public struct LedgerSplitPurchase: Equatable, Sendable {
  public let id: String
  public let accountID: String
  public let parentAmount: CurrencyAmount
  public let lines: [LedgerSplitLine]
  public let occurredAt: SourceTemporal
  public let note: String?
  public let origin: LedgerOrigin

  public var purchaseID: String { id }
  public var total: CurrencyAmount { parentAmount }

  public init(
    id: String, accountID: String, parentAmount: CurrencyAmount, lines: [LedgerSplitLine],
    occurredAt: SourceTemporal, note: String? = nil, origin: LedgerOrigin
  ) throws {
    let draft = try LedgerSplitDraft(
      id: id, accountID: accountID, parentAmount: parentAmount, lines: lines,
      occurredAt: occurredAt, note: note, origin: origin)
    self.id = draft.id
    self.accountID = draft.accountID
    self.parentAmount = draft.parentAmount
    self.lines = draft.lines
    self.occurredAt = draft.occurredAt
    self.note = draft.note
    self.origin = draft.origin
  }
}

/// Split groups read without failing: the purchases that parsed, and the transactions of any
/// group that did not, so a caller can still show those rows and say why.
public struct LedgerSplitPurchaseListing: Equatable, Sendable {
  public let purchases: [LedgerSplitPurchase]
  public let unreadableTransactionIDs: Set<String>
  public let unreadableGroupCount: Int

  public init(
    purchases: [LedgerSplitPurchase], unreadableTransactionIDs: Set<String>,
    unreadableGroupCount: Int
  ) {
    self.purchases = purchases
    self.unreadableTransactionIDs = unreadableTransactionIDs
    self.unreadableGroupCount = unreadableGroupCount
  }

  /// User-facing notice when some split groups could not be read; nil when all were read.
  public var unreadableNotice: String? {
    switch unreadableGroupCount {
    case 0: return nil
    case 1:
      return "1 split purchase could not be read. Its transactions are listed individually."
    default:
      return
        "\(unreadableGroupCount) split purchases could not be read. Their transactions are listed individually."
    }
  }
}

public enum LedgerRecurrenceFrequency: String, CaseIterable, Sendable {
  case daily
  case weekly
  case monthly
  case yearly
}

public enum LedgerEditScope: String, CaseIterable, Sendable {
  case thisOccurrence
  case thisAndFuture
}

public struct LedgerRecurrenceRule: Equatable, Sendable {
  public let id: String
  public let origin: LedgerOrigin
  public let accountID: String
  public let categoryID: String?
  public let kind: LedgerTransactionKind
  public let amount: CurrencyAmount
  public let frequency: LedgerRecurrenceFrequency
  public let interval: Int
  public let dayOfMonth: Int?
  public let timeZone: SourceTimeZone
  public let start: SourceLocalDate
  public let until: SourceLocalDate?
  public let paused: Bool
  public let skippedDates: [SourceLocalDate]
  public let lifecycle: LedgerLifecycleState

  public init(
    id: String, origin: LedgerOrigin, accountID: String, categoryID: String?,
    kind: LedgerTransactionKind, amount: CurrencyAmount, frequency: LedgerRecurrenceFrequency,
    interval: Int, dayOfMonth: Int? = nil, timeZone: SourceTimeZone, start: SourceLocalDate,
    until: SourceLocalDate? = nil, paused: Bool = false, skippedDates: [SourceLocalDate] = [],
    lifecycle: LedgerLifecycleState = .active
  ) throws {
    guard CanonicalIdentifier.isValid(id), CanonicalIdentifier.isValid(accountID),
      categoryID.map(CanonicalIdentifier.isValid) != false, interval > 0,
      kind == .income || kind == .expense,
      dayOfMonth.map({ $0 >= 1 && $0 <= 31 }) != false
    else { throw LedgerCommandError.invalidRecurrence }
    self.id = id
    self.origin = origin
    self.accountID = accountID
    self.categoryID = categoryID
    self.kind = kind
    self.amount = amount
    self.frequency = frequency
    self.interval = interval
    self.dayOfMonth = dayOfMonth
    self.timeZone = timeZone
    self.start = start
    self.until = until
    self.paused = paused
    self.skippedDates = skippedDates
    self.lifecycle = lifecycle
  }
}

public struct LedgerBudget: Equatable, Sendable {
  public enum Period: String, CaseIterable, Sendable { case monthly, yearly }

  public let id: String
  public let origin: LedgerOrigin
  public let name: String
  public let categoryID: String
  public let amount: CurrencyAmount
  public let period: Period
  public let rollover: Bool
  public let start: SourceLocalDate
  public let lifecycle: LedgerLifecycleState

  public init(
    id: String, origin: LedgerOrigin, name: String, categoryID: String, amount: CurrencyAmount,
    period: Period, rollover: Bool, start: SourceLocalDate,
    lifecycle: LedgerLifecycleState = .active
  ) throws {
    guard CanonicalIdentifier.isValid(id), CanonicalIdentifier.isValid(categoryID),
      !name.isEmpty, name.utf8.count <= 256
    else { throw LedgerCommandError.invalidBudget }
    self.id = id
    self.origin = origin
    self.name = name
    self.categoryID = categoryID
    self.amount = amount
    self.period = period
    self.rollover = rollover
    self.start = start
    self.lifecycle = lifecycle
  }
}

public struct LedgerInstallmentPlan: Equatable, Sendable {
  public enum Lifecycle: String, CaseIterable, Sendable { case active, cancelled, completed }

  public let id: String
  public let origin: LedgerOrigin
  public let accountID: String
  public let categoryID: String?
  public let principal: CurrencyAmount
  public let occurrenceCount: Int
  public let completedCount: Int
  public let lifecycle: Lifecycle

  public init(
    id: String, origin: LedgerOrigin, accountID: String, categoryID: String?,
    principal: CurrencyAmount, occurrenceCount: Int, completedCount: Int = 0,
    lifecycle: Lifecycle = .active
  ) throws {
    guard CanonicalIdentifier.isValid(id), CanonicalIdentifier.isValid(accountID),
      categoryID.map(CanonicalIdentifier.isValid) != false, occurrenceCount > 0,
      completedCount >= 0, completedCount <= occurrenceCount
    else { throw LedgerCommandError.invalidInstallment }
    self.id = id
    self.origin = origin
    self.accountID = accountID
    self.categoryID = categoryID
    self.principal = principal
    self.occurrenceCount = occurrenceCount
    self.completedCount = completedCount
    self.lifecycle = lifecycle
  }
}

public struct LedgerSearchQuery: Equatable, Sendable {
  public var accountID: String?
  public var accountHidden: Bool?
  public var accountIncludedInTotals: Bool?
  public var categoryID: String?
  public var noteContains: String?
  public var tagContains: String?
  public var textContains: String?
  public var kind: LedgerTransactionKind?
  public var lifecycle: LedgerLifecycleState?
  public var occurredOnOrAfter: SourceLocalDate?
  public var occurredOnOrBefore: SourceLocalDate?
  public var minimumAmount: ExactDecimal?
  public var maximumAmount: ExactDecimal?
  public var unitCode: String?
  public var hasCorrections: Bool?
  public var includeTombstones: Bool

  public init(
    accountID: String? = nil, accountHidden: Bool? = nil,
    accountIncludedInTotals: Bool? = nil, categoryID: String? = nil, noteContains: String? = nil,
    tagContains: String? = nil, textContains: String? = nil, kind: LedgerTransactionKind? = nil,
    lifecycle: LedgerLifecycleState? = nil, occurredOnOrAfter: SourceLocalDate? = nil,
    occurredOnOrBefore: SourceLocalDate? = nil, minimumAmount: ExactDecimal? = nil,
    maximumAmount: ExactDecimal? = nil, unitCode: String? = nil, hasCorrections: Bool? = nil,
    includeTombstones: Bool = false
  ) {
    self.accountID = accountID
    self.accountHidden = accountHidden
    self.accountIncludedInTotals = accountIncludedInTotals
    self.categoryID = categoryID
    self.noteContains = noteContains
    self.tagContains = tagContains
    self.textContains = textContains
    self.kind = kind
    self.lifecycle = lifecycle
    self.occurredOnOrAfter = occurredOnOrAfter
    self.occurredOnOrBefore = occurredOnOrBefore
    self.minimumAmount = minimumAmount
    self.maximumAmount = maximumAmount
    self.unitCode = unitCode
    self.hasCorrections = hasCorrections
    self.includeTombstones = includeTombstones
  }
}

public struct LedgerReportRow: Equatable, Sendable, Identifiable {
  public let id: String
  public let label: String
  public let amountLiteral: String
  public let unitCode: String
  public let count: Int

  public init(id: String, label: String, amountLiteral: String, unitCode: String, count: Int) {
    self.id = id
    self.label = label
    self.amountLiteral = amountLiteral
    self.unitCode = unitCode
    self.count = count
  }
}

public struct LedgerReport: Equatable, Sendable {
  public let title: String
  public let rows: [LedgerReportRow]
  public let categoryRows: [LedgerReportRow]
  public let inventory: [LedgerReportRow]
  public let totalLiteral: String
  public let unitCode: String

  public init(
    title: String, rows: [LedgerReportRow], totalLiteral: String, unitCode: String,
    inventory: [LedgerReportRow] = [], categoryRows: [LedgerReportRow] = []
  ) {
    self.title = title
    self.rows = rows
    self.categoryRows = categoryRows
    self.inventory = inventory
    self.totalLiteral = totalLiteral
    self.unitCode = unitCode
  }

  public var accessibleTable: String {
    let activity = rows.map { "\($0.label): \($0.amountLiteral) \($0.unitCode) (\($0.count))" }
    let categories = categoryRows.map {
      "Category \($0.label): \($0.amountLiteral) \($0.unitCode) (\($0.count))"
    }
    let counts = inventory.map { "\($0.label): \($0.count)" }
    return ([title] + activity + categories + ["Total: \(totalLiteral) \(unitCode)"] + counts)
      .joined(separator: "\n")
  }
}

public struct LedgerProjection: Equatable, Sendable {
  public let report: LedgerReport

  public init(report: LedgerReport) {
    self.report = report
  }

  public func discard() {}
}

public enum LedgerPortablePackageFormat {
  public static let version = 2
  public static let fingerprint =
    "5625a6dea5c0103a7bdaf216491d0e96397887eaf2cf93b73261f242d1b8766c"
  public static let legacyV1Version = 1
  public static let legacyV1Fingerprint =
    "b2a8537dcfb66549c30e77f2d6318170550fd69d7cba092589f7f0b579711a2e"
  public static let legacyV10SchemaVersion = 10
  public static let legacyV10SchemaFingerprint =
    "aca9d078dd357cd64a6fe209e04fb7e3ac724525cf15b8c313e0b8177d2b6926"
}

public struct LedgerExportManifest: Equatable, Sendable {
  public let formatVersion: Int
  public let formatFingerprint: String
  public let payloadSHA256: String
  public let createdAtMilliseconds: Int64

  /// Source-compatible aliases for callers compiled against the v10-era package API.
  public var schemaVersion: Int { formatVersion }
  public var schemaFingerprint: String { formatFingerprint }

  public init(
    formatVersion: Int, formatFingerprint: String, payloadSHA256: String,
    createdAtMilliseconds: Int64
  ) {
    self.formatVersion = formatVersion
    self.formatFingerprint = formatFingerprint
    self.payloadSHA256 = payloadSHA256
    self.createdAtMilliseconds = createdAtMilliseconds
  }

  public init(
    schemaVersion: Int, schemaFingerprint: String, payloadSHA256: String,
    createdAtMilliseconds: Int64
  ) {
    self.init(
      formatVersion: schemaVersion, formatFingerprint: schemaFingerprint,
      payloadSHA256: payloadSHA256, createdAtMilliseconds: createdAtMilliseconds)
  }
}

public struct LedgerPreservedSourceRecord: Equatable, Sendable {
  public let table: String
  public let recordKey: String
  public let columnName: String
  public let storageClass: String
  public let payload: Data
  public let reasonCode: String

  public init(
    table: String, recordKey: String, columnName: String, storageClass: String, payload: Data,
    reasonCode: String
  ) {
    self.table = table
    self.recordKey = recordKey
    self.columnName = columnName
    self.storageClass = storageClass
    self.payload = payload
    self.reasonCode = reasonCode
  }
}

public struct LedgerCanonicalPackage: Equatable, Sendable {
  public let formatVersion: Int
  public let formatFingerprint: String
  public let accounts: [LedgerAccount]
  public let accountGroups: [LedgerAccountGroup]
  public let categories: [LedgerCategory]
  public let revisions: [LedgerTransactionRevision]
  public let links: [LedgerTransactionLink]
  public let recurrenceRules: [LedgerRecurrenceRule]
  public let budgets: [LedgerBudget]
  public let installmentPlans: [LedgerInstallmentPlan]
  public let preservedSource: [LedgerPreservedSourceRecord]

  public var schemaVersion: Int { formatVersion }
  public var schemaFingerprint: String { formatFingerprint }

  public init(
    formatVersion: Int, formatFingerprint: String, accounts: [LedgerAccount],
    accountGroups: [LedgerAccountGroup] = [],
    categories: [LedgerCategory], revisions: [LedgerTransactionRevision],
    links: [LedgerTransactionLink], recurrenceRules: [LedgerRecurrenceRule],
    budgets: [LedgerBudget], installmentPlans: [LedgerInstallmentPlan],
    preservedSource: [LedgerPreservedSourceRecord] = []
  ) {
    self.formatVersion = formatVersion
    self.formatFingerprint = formatFingerprint
    self.accounts = accounts
    self.accountGroups = accountGroups
    self.categories = categories
    self.revisions = revisions
    self.links = links
    self.recurrenceRules = recurrenceRules
    self.budgets = budgets
    self.installmentPlans = installmentPlans
    self.preservedSource = preservedSource
  }

  public init(
    schemaVersion: Int, schemaFingerprint: String, accounts: [LedgerAccount],
    accountGroups: [LedgerAccountGroup] = [],
    categories: [LedgerCategory], revisions: [LedgerTransactionRevision],
    links: [LedgerTransactionLink], recurrenceRules: [LedgerRecurrenceRule],
    budgets: [LedgerBudget], installmentPlans: [LedgerInstallmentPlan],
    preservedSource: [LedgerPreservedSourceRecord] = []
  ) {
    self.init(
      formatVersion: schemaVersion, formatFingerprint: schemaFingerprint, accounts: accounts,
      accountGroups: accountGroups,
      categories: categories, revisions: revisions, links: links,
      recurrenceRules: recurrenceRules, budgets: budgets, installmentPlans: installmentPlans,
      preservedSource: preservedSource)
  }
}

public protocol LedgerClient {
  func createAccount(_ account: LedgerAccount) throws
  func createAccountGroup(_ group: LedgerAccountGroup) throws
  func updateAccount(_ account: LedgerAccount) throws
  func updateAccountGroup(_ group: LedgerAccountGroup) throws
  func tombstoneAccount(_ accountID: String) throws
  func createCategory(_ category: LedgerCategory) throws
  func updateCategory(_ category: LedgerCategory) throws
  func tombstoneCategory(_ categoryID: String) throws
  func createTransaction(
    idempotencyKey: String, draft: LedgerTransactionDraft, createdAt: UTCInstant
  ) throws -> LedgerTransactionRevision
  func correctTransaction(
    transactionID: String, expectedCurrentRevisionID: String, draft: LedgerTransactionDraft,
    createdAt: UTCInstant
  ) throws -> LedgerTransactionRevision
  func tombstoneTransaction(
    transactionID: String, expectedCurrentRevisionID: String, createdAt: UTCInstant
  ) throws -> LedgerTransactionRevision
  func createTransfer(
    idempotencyKey: String, sourceAccountID: String, destinationAccountID: String,
    sourceAmount: CurrencyAmount, destinationAmount: CurrencyAmount, conversion: LedgerConversion?,
    fee: CurrencyAmount?, feeAccountID: String?, occurredAt: SourceTemporal, origin: LedgerOrigin,
    createdAt: UTCInstant
  ) throws -> (transfer: LedgerTransactionRevision, fee: LedgerTransactionRevision?)
  func createSplit(
    idempotencyKey: String, accountID: String, parentAmount: CurrencyAmount,
    components: [(amount: CurrencyAmount, categoryID: String)], occurredAt: SourceTemporal,
    origin: LedgerOrigin, createdAt: UTCInstant
  ) throws -> [LedgerTransactionRevision]
  func createSplit(_ draft: LedgerSplitDraft, createdAt: UTCInstant) throws -> LedgerSplitPurchase
  func splitPurchases() throws -> [LedgerSplitPurchase]
  func createInstallmentPlan(
    _ plan: LedgerInstallmentPlan, occurredAt: SourceTemporal, createdAt: UTCInstant
  ) throws -> [LedgerTransactionRevision]
  func createRecurrence(_ rule: LedgerRecurrenceRule) throws
  func updateRecurrence(_ rule: LedgerRecurrenceRule, scope: LedgerEditScope) throws
  func generateOccurrences(
    _ rule: LedgerRecurrenceRule, through end: SourceLocalDate, createdAt: UTCInstant
  ) throws -> [LedgerTransactionRevision]
  func createBudget(_ budget: LedgerBudget) throws
  func updateBudget(_ budget: LedgerBudget) throws
  func updateInstallmentPlan(_ plan: LedgerInstallmentPlan) throws
  func search(_ query: LedgerSearchQuery) throws -> [LedgerTransactionSnapshot]
  func report(unitCode: String) throws -> LedgerReport
  func makeProjection(unitCode: String) throws -> LedgerProjection
  func checksum() throws -> String
  func exportPackage() throws -> (manifest: LedgerExportManifest, payload: Data)
  func importPackage(manifest: LedgerExportManifest, payload: Data) throws
}
