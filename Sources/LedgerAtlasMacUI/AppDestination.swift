public enum AppDestination: String, CaseIterable, Hashable, Identifiable, Sendable {
  case onboarding
  case importReview
  case accounts
  case ledger
  case receipts
  case localAccess
  case categories
  case tags
  case transfers
  case recurrence
  case installments
  case budgets
  case insights
  case search
  case backupRestore
  case settings

  public static let defaultSelection: AppDestination = .ledger

  public var id: Self { self }

  public var title: String {
    switch self {
    case .onboarding:
      "Onboarding"
    case .importReview:
      "Import Review"
    case .accounts:
      "Accounts"
    case .ledger:
      "Ledger"
    case .receipts:
      "Receipts"
    case .localAccess:
      "Local Access"
    case .categories:
      "Categories"
    case .tags:
      "Tags & Memos"
    case .transfers:
      "Transfers"
    case .recurrence:
      "Recurrence"
    case .installments:
      "Installments"
    case .budgets:
      "Budgets"
    case .insights:
      "Insights"
    case .search:
      "Search"
    case .backupRestore:
      "Backup"
    case .settings:
      "Settings"
    }
  }

  public var accessibilityLabel: String { title }

  public var accessibilityHint: String {
    switch self {
    case .onboarding:
      "Start a local Ledger Atlas workspace."
    case .importReview:
      "Review a Mac or iOS Money Manager backup before commit."
    case .accounts:
      "Show canonical accounts."
    case .ledger:
      "Show the canonical ledger."
    case .receipts:
      "Import receipt images and review local OCR suggestions without changing financial truth."
    case .localAccess:
      "Start a temporary read-only loopback status view for this Mac."
    case .categories:
      "Show canonical categories."
    case .tags:
      "Manage tags, transaction templates and day memos."
    case .transfers:
      "Show linked transfers."
    case .recurrence:
      "Show recurrence rules."
    case .installments:
      "Show installment plans."
    case .budgets:
      "Show budgets."
    case .insights:
      "Show reports and accessible tables."
    case .search:
      "Search canonical transactions."
    case .backupRestore:
      "Back up or restore a ledger package."
    case .settings:
      "Show Ledger Atlas settings."
    }
  }

  var systemImageName: String {
    switch self {
    case .onboarding:
      "hand.wave"
    case .importReview:
      "checklist.checked"
    case .accounts:
      "rectangle.stack"
    case .ledger:
      "list.bullet.rectangle"
    case .receipts:
      "doc.text.image"
    case .localAccess:
      "network"
    case .categories:
      "tag"
    case .tags:
      "number"
    case .transfers:
      "arrow.left.arrow.right"
    case .recurrence:
      "repeat"
    case .installments:
      "calendar"
    case .budgets:
      "chart.bar"
    case .insights:
      "chart.xyaxis.line"
    case .search:
      "magnifyingglass"
    case .backupRestore:
      "externaldrive"
    case .settings:
      "gearshape"
    }
  }

  var emptyStateMessage: String {
    switch self {
    case .onboarding:
      "Choose a Money Manager backup or an existing ledger to begin."
    case .importReview:
      "Import Review shows profile, counts, and blocking reasons without private values."
    case .accounts:
      "Canonical accounts appear after a successful import or ledger open."
    case .ledger:
      "Canonical transactions appear after a successful import or ledger open."
    case .receipts:
      "Receipt images stay private. OCR suggestions require explicit review and never write automatically."
    case .localAccess:
      "The portal is loopback-only, token-protected, and contains no mutation endpoint."
    case .categories:
      "Canonical categories are listed from the opened ledger."
    case .tags:
      "Tags, templates and memos are listed from the opened ledger."
    case .transfers:
      "Linked transfers are listed from the opened ledger."
    case .recurrence:
      "Recurrence rules are listed from the opened ledger."
    case .installments:
      "Installment plans are listed from the opened ledger."
    case .budgets:
      "Budgets are listed from the opened ledger."
    case .insights:
      "Reports reconcile to canonical events and include an accessible table."
    case .search:
      "Search filters the opened canonical ledger."
    case .backupRestore:
      "Save an exact canonical SQLite backup. Portable packages are limited to Mac-native ledgers."
    case .settings:
      "Reduced motion and privacy redaction stay enabled."
    }
  }
}
