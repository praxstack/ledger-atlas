import CryptoKit
import Foundation

/// What importing an XLSX workbook into an open ledger would do, worked out before anything
/// is written, so the person can preview it and the store can apply it in one step.
///
/// Import only adds. A record whose id the ledger already has is left as it is: when it
/// matches it is skipped, and when it differs the plan reports a conflict and cannot be
/// applied. Imported transactions take the XLSX import origin and an idempotency key derived
/// from their exported id: importing the same rows twice adds nothing the second time, and a
/// row whose content changed since it was imported is a conflict, never a second copy.
public struct LedgerXLSXImportPlan: Equatable, Sendable {
  public struct NewTransaction: Equatable, Sendable {
    /// The id in the workbook. The ledger stores the transaction under the id that
    /// `idempotencyKey` and the XLSX import origin derive.
    public let exportedID: String
    public let idempotencyKey: String
    public let draft: LedgerTransactionDraft
    public let tags: LedgerTagLinks
  }

  /// What is already in the ledger, by id.
  public struct Existing: Sendable {
    public var accountGroups: [String: LedgerAccountGroup]
    public var accounts: [String: LedgerAccount]
    public var categories: [String: LedgerCategory]
    public var tags: [String: LedgerTag]
    public var transactions: [String: LedgerXLSXExchange.Transaction]

    public init(
      accountGroups: [LedgerAccountGroup] = [], accounts: [LedgerAccount] = [],
      categories: [LedgerCategory] = [], tags: [LedgerTag] = [],
      transactions: [LedgerXLSXExchange.Transaction] = []
    ) {
      self.accountGroups = Dictionary(accountGroups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
      self.accounts = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
      self.categories = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
      self.tags = Dictionary(tags.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
      self.transactions = Dictionary(
        transactions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
  }

  public struct Summary: Equatable, Sendable {
    public var added = 0
    public var unchanged = 0

    public init(added: Int = 0, unchanged: Int = 0) {
      self.added = added
      self.unchanged = unchanged
    }
  }

  public let accountGroups: [LedgerAccountGroup]
  public let accounts: [LedgerAccount]
  /// Parents before children, so they can be created in this order.
  public let categories: [LedgerCategory]
  public let tags: [LedgerTag]
  public let transactions: [NewTransaction]
  /// Records whose id the ledger has with different content. A plan with conflicts is not
  /// applied.
  public let conflicts: [LedgerXLSXExchange.Issue]
  /// Deleted transactions in the workbook. They are not imported.
  public let skippedDeletedTransactions: Int
  public let summary: [String: Summary]

  public var canApply: Bool { conflicts.isEmpty }
  public var isEmpty: Bool {
    accountGroups.isEmpty && accounts.isEmpty && categories.isEmpty && tags.isEmpty
      && transactions.isEmpty
  }

  public init(content: LedgerXLSXExchange.Content, existing: Existing) {
    var conflicts: [LedgerXLSXExchange.Issue] = []
    var summary: [String: Summary] = [:]

    func split<T: Equatable>(
      _ records: [T], sheet: String, id: (T) -> String, name: (T) -> String,
      existing: [String: T]
    ) -> [T] {
      var added: [T] = []
      var counts = Summary()
      for record in records {
        if let current = existing[id(record)] {
          if current == record {
            counts.unchanged += 1
          } else {
            conflicts.append(
              LedgerXLSXExchange.Issue(
                sheet: sheet, column: "id",
                message: "“\(name(record))” already exists in this ledger with different details. Import never changes existing records."))
          }
        } else {
          added.append(record)
          counts.added += 1
        }
      }
      summary[sheet] = counts
      return added
    }

    accountGroups = split(
      content.accountGroups, sheet: LedgerXLSXExchange.Sheet.accountGroups, id: \.id,
      name: \.name, existing: existing.accountGroups)
    accounts = split(
      content.accounts, sheet: LedgerXLSXExchange.Sheet.accounts, id: \.id, name: \.name,
      existing: existing.accounts)
    let newCategories = split(
      content.categories, sheet: LedgerXLSXExchange.Sheet.categories, id: \.id, name: \.name,
      existing: existing.categories)
    tags = split(
      content.tags, sheet: LedgerXLSXExchange.Sheet.tags, id: \.id, name: \.name,
      existing: existing.tags)
    categories = Self.parentsFirst(newCategories)

    var transactions: [NewTransaction] = []
    var counts = Summary()
    var deleted = 0
    for transaction in content.transactions.sorted(by: { $0.id < $1.id }) {
      guard transaction.lifecycle == .active else {
        deleted += 1
        continue
      }
      if let current = existing.transactions[transaction.id] {
        // Exported from this ledger. Unchanged rows are skipped; an edited row would change
        // an existing transaction, which import never does.
        if current.draft == transaction.draft, current.tags == transaction.tags,
          current.lifecycle == .active
        {
          counts.unchanged += 1
        } else {
          conflicts.append(
            LedgerXLSXExchange.Issue(
              sheet: LedgerXLSXExchange.Sheet.transactions, column: "id",
              message: "Transaction \(transaction.id.prefix(8))… already exists in this ledger with different details. Import never changes existing records; edit it in the app instead."))
        }
        continue
      }
      guard let draft = try? Self.reoriginated(transaction.draft) else {
        conflicts.append(
          LedgerXLSXExchange.Issue(
            sheet: LedgerXLSXExchange.Sheet.transactions, column: "id",
            message: "Transaction \(transaction.id.prefix(8))… could not be prepared for import."))
        continue
      }
      let key = Self.idempotencyKey(for: transaction)
      let derived = try? StableLedgerID.transaction(origin: draft.origin, localKey: key)
      if let derived, let imported = existing.transactions[derived] {
        // Imported before. The same content is skipped; anything else would change it.
        if imported.draft == draft, imported.tags == transaction.tags,
          imported.lifecycle == .active
        {
          counts.unchanged += 1
        } else {
          conflicts.append(
            LedgerXLSXExchange.Issue(
              sheet: LedgerXLSXExchange.Sheet.transactions, column: "id",
              message: "Transaction \(transaction.id.prefix(8))… was already imported with different details. Import never changes existing records; edit it in the app instead."))
        }
        continue
      }
      // Checked after the already-imported case: a row imported earlier may use a record
      // that was deleted since, and re-importing it should still change nothing.
      if let problem = Self.deletedReference(transaction, existing: existing) {
        conflicts.append(
          LedgerXLSXExchange.Issue(
            sheet: LedgerXLSXExchange.Sheet.transactions, column: "id",
            message: "Transaction \(transaction.id.prefix(8))… uses \(problem), which is deleted in this ledger. New transactions can only use active records."))
        continue
      }
      transactions.append(
        NewTransaction(
          exportedID: transaction.id, idempotencyKey: key, draft: draft, tags: transaction.tags))
      counts.added += 1
    }
    summary[LedgerXLSXExchange.Sheet.transactions] = counts
    self.transactions = transactions
    self.skippedDeletedTransactions = deleted
    self.conflicts = conflicts
    self.summary = summary
  }

  /// The origin every imported transaction gets, so health checks and the browser can tell
  /// imported rows from ones made in the app.
  public static let originLabel = "xlsx-import"
  public static func origin() throws -> LedgerOrigin {
    try LedgerOrigin(id: hex(Data("ledger-atlas-xlsx-import-origin".utf8)), label: originLabel)
  }

  /// A record the transaction points at that this ledger has deleted. Records that come
  /// from the workbook are created active first, so only ones already here can be deleted.
  static func deletedReference(
    _ transaction: LedgerXLSXExchange.Transaction, existing: Existing
  ) -> String? {
    for effect in transaction.draft.effects {
      if let account = existing.accounts[effect.accountID], account.lifecycle != .active {
        return "account “\(account.name)”"
      }
    }
    if let id = transaction.draft.categoryID, let category = existing.categories[id],
      category.lifecycle != .active
    {
      return "category “\(category.name)”"
    }
    for id in transaction.tags.tagIDs {
      if let tag = existing.tags[id], tag.lifecycle != .active { return "tag “\(tag.name)”" }
    }
    return nil
  }

  static func reoriginated(_ draft: LedgerTransactionDraft) throws -> LedgerTransactionDraft {
    try LedgerTransactionDraft(
      effects: draft.effects, categoryID: draft.categoryID, kind: draft.kind,
      occurredAt: draft.occurredAt, note: draft.note, roundingPolicy: draft.roundingPolicy,
      sourceLiterals: draft.sourceLiterals, origin: origin())
  }

  /// Hash of the exported id alone. The same exported row always maps to the same stored
  /// transaction, so a row edited and exported again is a conflict, never a second copy.
  public static func idempotencyKey(for transaction: LedgerXLSXExchange.Transaction) -> String {
    let fields = ["ledger-atlas-xlsx-import/1", transaction.id]
    // Length-prefixed, so no two different field lists hash the same text.
    let text = fields.map { "\($0.utf8.count):\($0)" }.joined()
    return hex(Data(text.utf8))
  }

  static func hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func parentsFirst(_ categories: [LedgerCategory]) -> [LedgerCategory] {
    let ids = Set(categories.map(\.id))
    var placed: Set<String> = []
    var ordered: [LedgerCategory] = []
    var pending = categories.sorted { $0.id < $1.id }
    while !pending.isEmpty {
      let before = pending.count
      pending.removeAll { category in
        guard let parent = category.parentID, ids.contains(parent), !placed.contains(parent)
        else {
          ordered.append(category)
          placed.insert(category.id)
          return true
        }
        return false
      }
      // Validation already refused loops; this only guards against an endless loop.
      if pending.count == before {
        ordered += pending
        break
      }
    }
    return ordered
  }
}
