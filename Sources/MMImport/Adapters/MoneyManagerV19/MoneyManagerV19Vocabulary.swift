import Foundation
import LedgerAdapterSemantics
import LedgerCore

/// Vendor table/column spellings stay in the adapter. The committer must not invent them.
typealias MoneyManagerV19Vocabulary = MoneyManagerV19Semantics

extension MoneyManagerV19Semantics {
  static func isTransactionTable(_ name: String) -> Bool { transactionTables.contains(name) }

  static func reason(forType type: String) -> MoneyManagerV19BlockReason? {
    switch type {
    case "0", "1": nil
    case "3", "4": .transferDirectionUnproven
    case "7": .unknownTransactionType
    default: .unsupportedTransactionType
    }
  }

  /// Types 7 and 8 are quiet balance edits only when they carry the built-in balance-edit
  /// category. Any other type-7 or type-8 row keeps its preservation.
  /// Transfer legs carry no category; a transfer row that names one stays preserved.
  static func reason(forType type: String, categoryUID: String?) -> MoneyManagerV19BlockReason? {
    if isTransferType(type), categoryUID == nil || categoryUID == "" { return nil }
    if type == balanceIncreaseType || type == balanceDecreaseType,
      categoryUID == balanceEditCategoryUID
    {
      return nil
    }
    return reason(forType: type)
  }

  /// A balance edit has no category row; every other category must resolve.
  static func categoryResolves(_ categoryUID: String, known: Set<String>) -> Bool {
    categoryUID == balanceEditCategoryUID || known.contains(categoryUID)
  }

  /// The canonical kind for an admitted source type literal.
  static func eventKind(forType type: String) -> MoneyManagerV19EventKind? {
    switch type {
    case "0": .income
    case "1": .expense
    case balanceIncreaseType: .adjustment
    case balanceDecreaseType: .adjustmentDebit
    case transferDebitType: .transferDebit
    case transferCreditType: .transferCredit
    default: nil
    }
  }

  static func reconciliationReason(_ reason: MoneyManagerV19BlockReason) -> ReconciliationReasonCode
  {
    switch reason {
    case .unknownTransactionType, .unsupportedTransactionType:
      .unresolvedTransactionType
    case .transferDirectionUnproven:
      .transferDirectionUnproven
    case .unresolvedCategory:
      .unresolvedCategory
    case .missingRequiredField, .invalidObservedLiteral, .nonTextField:
      .unresolvedSourceBinding
    default:
      .opaqueSidecarPreserved
    }
  }

  // MARK: Recurring rules (REPEATTRANSACTION)

  static let recurrenceTables: Set<String> = ["REPEATTRANSACTION", "ZREPEATTRANSACTION"]
  static let repeatTypeAliases = ["REPEAT_TYPE", "ZREPEATTYPE"]
  static let nextDateAliases = ["NEXT_DATE", "ZNEXTDATE"]
  static let endDateAliases = ["END_DATE", "ZENDDATE"]
  static let recurrenceAmountAliases = ["AMOUNT_SUB", "ZAMOUNTSUB"]
  static let deletedAliases = ["IS_DEL", "ZISDEL"]
  static let toAssetAliases = ["toAssetUid", "TO_ASSET_UID", "ZTOASSETUID"]

  /// Observed REPEAT_TYPE codes that a Ledger Atlas rule can express exactly. Weekend (10) has
  /// no Ledger Atlas frequency, and unseen codes are never guessed: those rules stay preserved.
  static func recurrence(forRepeatType code: String) -> (
    frequency: LedgerRecurrenceFrequency, interval: Int
  )? {
    switch code {
    case "1": (.monthly, 1)
    case "5": (.daily, 1)
    case "7": (.weekly, 2)
    case "17": (.yearly, 1)
    default: nil
    }
  }

  /// A rule amount exists only as REAL `AMOUNT_SUB`. It is admitted when the binary64 value is
  /// positive and is exactly the nearest double to a two-decimal literal; anything else stays
  /// preserved raw rather than rounded.
  static func recurrenceAmountLiteral(realPayload: Data) -> String? {
    guard realPayload.count == 8 else { return nil }
    let bits = realPayload.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    let value = Double(bitPattern: bits)
    guard value.isFinite, value > 0, value < 1e13 else { return nil }
    let literal = String(format: "%.2f", value)
    guard Double(literal) == value, (try? ExactDecimal(literal)) != nil else { return nil }
    return literal
  }

  /// Ledger Atlas rule id for a source rule uid: stable across re-imports of the same backup.
  static func recurrenceRuleID(profileID: String, sourceRuleUID: String) -> String {
    CanonicalReceiptDigest.hash(["ledger-atlas/mm-recurrence/v1", profileID, sourceRuleUID])
  }

  /// Local calendar day of an epoch-millisecond instant in the source time zone.
  static func localDate(epochMilliseconds: Int64, in zone: SourceTimeZone) -> SourceLocalDate? {
    let offset: Int
    if let fixed = zone.fixedOffsetSeconds {
      offset = fixed
    } else if let identifier = zone.ianaIdentifier, let foundation = TimeZone(identifier: identifier) {
      offset = foundation.secondsFromGMT(
        for: Date(timeIntervalSince1970: Double(epochMilliseconds) / 1_000))
    } else {
      return nil
    }
    let (shifted, overflow) = epochMilliseconds.addingReportingOverflow(Int64(offset) * 1_000)
    guard !overflow else { return nil }
    let civil = GregorianCivil.components(epochMilliseconds: shifted)
    return try? SourceLocalDate(year: civil.year, month: civil.month, day: civil.day)
  }

  static func blocksLosslessCertification(_ reason: MoneyManagerV19BlockReason) -> Bool {
    switch reason {
    case .unknownTransactionType, .unsupportedTransactionType, .transferDirectionUnproven:
      true
    default:
      false
    }
  }
}
