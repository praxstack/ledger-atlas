import Foundation
import LedgerCore

/// One change applied to many ledger entries at once (#168).
public enum LedgerBulkChange: Equatable, Hashable, Sendable {
  /// Sets the category; nil leaves the entries with no category.
  case category(String?)
  case addTag(String)
  case removeTag(String)
}

/// Why a bulk change was not made. Nothing is written when one of these is thrown.
public enum LedgerBulkEditRefusal: Error, Equatable, Sendable {
  case nothingSelected
  /// Transfers have no category, so a category can't be set on them.
  case transfersHaveNoCategory(count: Int)
  /// A split's lines keep their own categories; the split is edited instead.
  case splitLinesKeepTheirCategories(count: Int)
  /// The category is for another kind of entry (an expense category on income, for example).
  case categoryDoesNotFit(count: Int)
  /// The category or tag is not in this ledger, or has been closed.
  case unavailableCategoryOrTag
  /// Entries on a closed account can't be changed until the account is reopened.
  case closedAccount(count: Int)
  /// Closed (deleted) entries can't be changed.
  case closedEntries(count: Int)
  /// Every selected entry is already as asked.
  case nothingToChange
  /// Reverting: these entries were changed again after the bulk change, so it is left as is.
  case changedSince(count: Int)
}

/// What a bulk change will do, worked out before anything is written: the confirm sheet shows
/// its counts, and `LedgerApplication.applyBulkEdit` writes exactly these revisions.
public struct LedgerBulkEditPlan: Sendable {
  package struct Target: Sendable {
    package let current: LedgerTransactionRevision
    package let currentTags: LedgerTagLinks
    package let draft: LedgerTransactionDraft
    package let tags: LedgerTagLinks
  }

  public let change: LedgerBulkChange
  /// Entries the person selected.
  public let selectedCount: Int
  /// Entries added because they are linked to a selected one (the other payments of an
  /// installment plan, the lines of a split, a transfer's fee).
  public let linkedCount: Int
  /// Entries already as asked; they get no new revision.
  public let unchangedCount: Int
  package let targets: [Target]

  /// Entries that get a new revision.
  public var changeCount: Int { targets.count }

  /// Works out the change against `snapshot`. Throws `LedgerBulkEditRefusal` when the change
  /// can't be made as a whole.
  public static func make(
    _ change: LedgerBulkChange, transactionIDs: [String],
    in snapshot: LedgerStore.LedgerReadSnapshot
  ) throws -> LedgerBulkEditPlan {
    let selected = Array(Set(transactionIDs))
    guard !selected.isEmpty else { throw LedgerBulkEditRefusal.nothingSelected }
    let byID = Dictionary(
      snapshot.transactions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let group = linkedGroup(of: selected, in: byID)
    let entries = group.compactMap { byID[$0] }
    let closed = entries.filter { $0.currentRevision.lifecycle != .active }.count
    guard closed == 0 else { throw LedgerBulkEditRefusal.closedEntries(count: closed) }

    switch change {
    case .category(let categoryID):
      if let categoryID {
        guard
          let category = snapshot.categories.first(where: { $0.id == categoryID }),
          category.lifecycle == .active
        else { throw LedgerBulkEditRefusal.unavailableCategoryOrTag }
        let transfers = entries.filter { $0.currentRevision.draft.kind == .transfer }.count
        guard transfers == 0 else {
          throw LedgerBulkEditRefusal.transfersHaveNoCategory(count: transfers)
        }
        let misfits = entries.filter { !category.kind.accepts($0.currentRevision.draft.kind) }
          .count
        guard misfits == 0 else { throw LedgerBulkEditRefusal.categoryDoesNotFit(count: misfits) }
      } else {
        let transfers = entries.filter { $0.currentRevision.draft.kind == .transfer }.count
        guard transfers == 0 else {
          throw LedgerBulkEditRefusal.transfersHaveNoCategory(count: transfers)
        }
      }
      let splitLines = entries.filter { entry in entry.links.contains { $0.kind == .split } }.count
      guard splitLines == 0 else {
        throw LedgerBulkEditRefusal.splitLinesKeepTheirCategories(count: splitLines)
      }
    case .addTag(let tagID):
      guard snapshot.tags.contains(where: { $0.id == tagID && $0.lifecycle == .active }) else {
        throw LedgerBulkEditRefusal.unavailableCategoryOrTag
      }
    case .removeTag:
      break
    }

    var targets: [Target] = []
    var unchanged = 0
    for entry in entries {
      let current = entry.currentRevision
      let currentTags = snapshot.tags(forRevision: current.id)
      var categoryID = current.draft.categoryID
      var tagIDs = currentTags.tagIDs
      switch change {
      case .category(let newCategory): categoryID = newCategory
      case .addTag(let tagID): if !tagIDs.contains(tagID) { tagIDs.append(tagID) }
      case .removeTag(let tagID): tagIDs.removeAll { $0 == tagID }
      }
      let tags = try LedgerTagLinks(tagIDs)
      guard categoryID != current.draft.categoryID || tags != currentTags else {
        unchanged += 1
        continue
      }
      targets.append(
        Target(
          current: current, currentTags: currentTags,
          draft: try correctedDraft(current.draft, categoryID: categoryID), tags: tags))
    }
    guard !targets.isEmpty else { throw LedgerBulkEditRefusal.nothingToChange }
    let closedAccounts = Set(snapshot.accounts.filter { $0.lifecycle != .active }.map(\.id))
    let onClosed = targets.filter { target in
      target.draft.effects.contains { closedAccounts.contains($0.accountID) }
    }.count
    guard onClosed == 0 else { throw LedgerBulkEditRefusal.closedAccount(count: onClosed) }
    return LedgerBulkEditPlan(
      change: change, selectedCount: selected.count,
      linkedCount: group.count - selected.filter { byID[$0] != nil }.count,
      unchangedCount: unchanged, targets: targets)
  }

  /// The selected entries and everything linked to them as one item: a split's lines, an
  /// installment plan's payments, a transfer and its fee. Recurring occurrences stay separate:
  /// each date is its own entry.
  static func linkedGroup(
    of selected: [String], in byID: [String: LedgerTransactionSnapshot]
  ) -> [String] {
    var seen = Set<String>()
    var queue = selected.filter { byID[$0] != nil }
    var ordered: [String] = []
    while let id = queue.popLast() {
      guard seen.insert(id).inserted, let entry = byID[id] else { continue }
      ordered.append(id)
      for link in entry.links where link.kind != .recurring {
        let other = link.fromTransactionID == id ? link.toTransactionID : link.fromTransactionID
        if !seen.contains(other) { queue.append(other) }
      }
    }
    return ordered.sorted()
  }

  /// The draft with another category. Import receipt markers stay on the imported revision, as
  /// for any correction.
  static func correctedDraft(
    _ draft: LedgerTransactionDraft, categoryID: String?
  ) throws -> LedgerTransactionDraft {
    try LedgerTransactionDraft(
      effects: draft.effects, categoryID: categoryID, kind: draft.kind,
      occurredAt: draft.occurredAt, note: draft.note, roundingPolicy: draft.roundingPolicy,
      sourceLiterals: draft.sourceLiterals.filter { !$0.field.hasPrefix("import.") },
      origin: draft.origin)
  }
}

/// What a bulk change wrote, kept so it can be reverted as one step.
public struct LedgerBulkEditReceipt: Equatable, Sendable {
  public struct Entry: Equatable, Sendable {
    public let transactionID: String
    /// The revision the bulk change replaced, and its tags.
    public let before: LedgerTransactionRevision
    public let beforeTags: LedgerTagLinks
    /// The revision the bulk change wrote.
    public let afterRevisionID: String
  }

  public let change: LedgerBulkChange
  public let entries: [Entry]
}
