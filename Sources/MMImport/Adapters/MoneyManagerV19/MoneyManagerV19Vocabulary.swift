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

  /// Type 7 is a balance decrease only when it carries the built-in balance-edit category.
  /// Any other type-7 row keeps its unknown-type preservation.
  static func reason(forType type: String, categoryUID: String?) -> MoneyManagerV19BlockReason? {
    if type == balanceDecreaseType, categoryUID == balanceEditCategoryUID { return nil }
    return reason(forType: type)
  }

  /// A balance edit has no category row; every other category must resolve.
  static func categoryResolves(_ categoryUID: String, known: Set<String>) -> Bool {
    categoryUID == balanceEditCategoryUID || known.contains(categoryUID)
  }

  /// Source type literals that map to an expense.
  static func isExpenseType(_ type: String) -> Bool { type == "1" || type == balanceDecreaseType }

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
