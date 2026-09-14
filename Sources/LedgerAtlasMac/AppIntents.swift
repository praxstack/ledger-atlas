import AppIntents
import Foundation
import LedgerAtlasMacUI

private enum LedgerIntentSupport {
  static func queue(
    _ kind: LedgerIntentRequest.Kind, amount: String? = nil, note: String? = nil
  ) throws -> some IntentResult & ProvidesDialog {
    do {
      try LedgerIntentBridge.enqueue(
        .init(kind: kind, amountLiteral: amount, note: note))
      return .result(dialog: "Ledger Atlas will open for confirmation before saving.")
    } catch LedgerIntentError.alreadyPending {
      return .result(dialog: "Ledger Atlas already has a pending request. Open it to review first.")
    } catch {
      return .result(dialog: "Ledger Atlas could not queue the request.")
    }
  }
}

struct AddExpenseIntent: AppIntent {
  static let title: LocalizedStringResource = "Add Expense"
  static let description = IntentDescription("Open Ledger Atlas to review and add an expense.")
  static let openAppWhenRun = true

  @Parameter(title: "Amount") var amount: String
  @Parameter(title: "Note") var note: String?

  init() {
    _amount = Parameter(title: "Amount")
    _note = Parameter(title: "Note")
  }

  func perform() async throws -> some IntentResult & ProvidesDialog {
    try LedgerIntentSupport.queue(.addExpense, amount: amount, note: note)
  }
}

struct AddIncomeIntent: AppIntent {
  static let title: LocalizedStringResource = "Add Income"
  static let description = IntentDescription("Open Ledger Atlas to review and add income.")
  static let openAppWhenRun = true

  @Parameter(title: "Amount") var amount: String
  @Parameter(title: "Note") var note: String?

  init() {
    _amount = Parameter(title: "Amount")
    _note = Parameter(title: "Note")
  }

  func perform() async throws -> some IntentResult & ProvidesDialog {
    try LedgerIntentSupport.queue(.addIncome, amount: amount, note: note)
  }
}

struct AddTransferIntent: AppIntent {
  static let title: LocalizedStringResource = "Add Transfer"
  static let description = IntentDescription("Open Ledger Atlas to review and add a transfer.")
  static let openAppWhenRun = true

  @Parameter(title: "Amount") var amount: String

  init() {
    _amount = Parameter(title: "Amount")
  }

  func perform() async throws -> some IntentResult & ProvidesDialog {
    try LedgerIntentSupport.queue(.addTransfer, amount: amount)
  }
}

struct CreateBackupIntent: AppIntent {
  static let title: LocalizedStringResource = "Create Backup"
  static let description = IntentDescription("Open Ledger Atlas to choose a backup destination.")
  static let openAppWhenRun = true

  func perform() async throws -> some IntentResult & ProvidesDialog {
    try LedgerIntentSupport.queue(.createBackup)
  }
}

struct OpenBudgetsIntent: AppIntent {
  static let title: LocalizedStringResource = "Open Budgets"
  static let description = IntentDescription("Open Ledger Atlas budgets.")
  static let openAppWhenRun = true

  func perform() async throws -> some IntentResult & ProvidesDialog {
    try LedgerIntentSupport.queue(.openBudgets)
  }
}
