import Foundation
import LedgerCore

/// Vendor table/column spellings stay in the adapter. The committer must not invent them.
enum MoneyManagerV19Vocabulary {
  static let accountTables: Set<String> = ["ASSETS", "ZASSETS"]
  static let categoryTables: Set<String> = ["ZCATEGORY", "CATEGORY"]
  static let currencyTables: Set<String> = ["CURRENCY", "ZCURRENCY"]
  static let transactionTables: Set<String> = ["INOUTCOME", "ZINOUTCOME"]
  static let recognizedTables = accountTables.union(categoryTables).union(currencyTables)
    .union(transactionTables)

  static let uidAliases = ["uid", "UID", "ZUID", "Z_PK"]
  static let isoAliases = ["ISO", "ZISO", "CODE"]
  static let nameAliases = ["name", "NAME", "ZNAME"]
  static let assetAliases = ["assetUid", "ASSET_UID", "ZASSETUID", "ZASSET"]
  static let currencyUIDAliases = [
    "currencyUid", "CURRENCY_UID", "ZCURRENCYUID", "ZCURRENCY",
  ]
  static let categoryAliases = ["ctgUid", "CTG_UID", "ZCTGUID", "ZCATEGORY"]
  static let doTypeAliases = ["DO_TYPE", "ZDOTYPE", "DOTYPE"]
  static let amountAliases = ["ZMONEY", "AMOUNT", "ZAMOUNT"]
  static let wdateAliases = ["WDATE", "ZWDATE"]
  static let zdateAliases = ["ZDATE"]

  static func isTransactionTable(_ name: String) -> Bool { transactionTables.contains(name) }

  static func mappingLiteral(storageClass: CanonicalFieldStorageClass, payload: Data, value: String)
    -> String?
  {
    if storageClass == .integer, payload.count == 8 {
      let bits = payload.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
      return String(Int64(bitPattern: bits))
    }
    if !value.isEmpty { return value }
    if let text = String(data: payload, encoding: .utf8), !text.isEmpty { return text }
    return nil
  }

  static func mappingLiteral(storageClass: String, payload: Data) -> String? {
    if storageClass == CanonicalFieldStorageClass.integer.rawValue, payload.count == 8 {
      let bits = payload.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
      return String(Int64(bitPattern: bits))
    }
    if let text = String(data: payload, encoding: .utf8), !text.isEmpty { return text }
    return nil
  }

  static func aliased<T>(_ values: [String: T], _ names: [String]) -> T? {
    for name in names {
      if let value = values[name] { return value }
    }
    return nil
  }

  static func reason(forType type: String) -> MoneyManagerV19BlockReason? {
    switch type {
    case "0", "1": nil
    case "3", "4": .transferDirectionUnproven
    case "7": .unknownTransactionType
    default: .unsupportedTransactionType
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

  static func blocksLosslessCertification(_ reason: MoneyManagerV19BlockReason) -> Bool {
    switch reason {
    case .unknownTransactionType, .unsupportedTransactionType, .transferDirectionUnproven:
      true
    default:
      false
    }
  }
}
