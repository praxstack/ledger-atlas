import Foundation
import LedgerCore

enum CategoryPresentation {
  static func label(_ category: LedgerCategory, in categories: [LedgerCategory]) -> String {
    CategoryTree(categories).label(for: category.id) ?? category.name
  }
}

/// Read-only view of a category forest of any depth.
///
/// Every operation tolerates damaged data: a missing parent makes the category a root,
/// and a parent cycle is cut so each category still appears exactly once.
struct CategoryTree {
  let categories: [LedgerCategory]
  private let byID: [String: LedgerCategory]
  private let childIDs: [String: [String]]
  private let rootIDs: [String]
  /// Each category's effective parent after orphans and cycles are cut.
  private let parentOf: [String: String]

  init(_ categories: [LedgerCategory]) {
    var byID: [String: LedgerCategory] = [:]
    for category in categories where byID[category.id] == nil { byID[category.id] = category }
    let unique = categories.filter { byID[$0.id] == $0 }
    self.categories = unique
    self.byID = byID

    var children: [String: [LedgerCategory]] = [:]
    var roots: [LedgerCategory] = []
    for category in unique {
      if let parentID = category.parentID, parentID != category.id, byID[parentID] != nil {
        children[parentID, default: []].append(category)
      } else {
        roots.append(category)
      }
    }
    for key in children.keys { children[key]?.sort(by: Self.order) }
    roots.sort(by: Self.order)

    // Walk from the roots. Anything left over sits in a parent cycle: promote the
    // first such category (in stable order) to a root, then walk again.
    var parentOf: [String: String] = [:]
    var reached: Set<String> = []
    func walk(_ id: String) {
      var pending = [id]
      reached.insert(id)
      while let current = pending.popLast() {
        for child in children[current] ?? [] where reached.insert(child.id).inserted {
          parentOf[child.id] = current
          pending.append(child.id)
        }
      }
    }
    for root in roots { walk(root.id) }
    for category in unique.sorted(by: Self.order) where !reached.contains(category.id) {
      roots.append(category)
      walk(category.id)
    }
    roots.sort(by: Self.order)

    self.rootIDs = roots.map(\.id)
    self.parentOf = parentOf
    var childIDs: [String: [String]] = [:]
    for (parent, list) in children {
      let kept = list.filter { parentOf[$0.id] == parent }.map(\.id)
      if !kept.isEmpty { childIDs[parent] = kept }
    }
    self.childIDs = childIDs
  }

  static func order(_ lhs: LedgerCategory, _ rhs: LedgerCategory) -> Bool {
    if lhs.displayOrder != rhs.displayOrder { return lhs.displayOrder < rhs.displayOrder }
    if lhs.name != rhs.name { return lhs.name < rhs.name }
    return lhs.id < rhs.id
  }

  subscript(id: String) -> LedgerCategory? { byID[id] }

  /// Ordered children of `id`, or the roots when `id` is nil.
  func children(of id: String?) -> [LedgerCategory] {
    let ids = id.map { childIDs[$0] ?? [] } ?? rootIDs
    return ids.compactMap { byID[$0] }
  }

  func parent(of id: String) -> LedgerCategory? { parentOf[id].flatMap { byID[$0] } }

  /// Root first, `id` last. Empty when `id` is unknown.
  func path(to id: String) -> [LedgerCategory] {
    var path: [LedgerCategory] = []
    var cursor: String? = id
    while let current = cursor, let category = byID[current] {
      path.append(category)
      cursor = parentOf[current]
    }
    return path.reversed()
  }

  func depth(of id: String) -> Int { max(path(to: id).count - 1, 0) }

  func label(for id: String) -> String? {
    let path = path(to: id)
    return path.isEmpty ? nil : path.map(\.name).joined(separator: " › ")
  }

  func descendantIDs(of id: String) -> Set<String> {
    var result: Set<String> = []
    var pending = [id]
    while let current = pending.popLast() {
      for child in childIDs[current] ?? [] where result.insert(child).inserted {
        pending.append(child)
      }
    }
    return result
  }

  /// Parents a category of `kind` may move under: active, visible, the same kind, and
  /// not `movingID` or one of its descendants (which would create a cycle).
  func validParents(for kind: LedgerCategoryKind, movingID: String? = nil) -> [LedgerCategory] {
    let excluded = movingID.map { descendantIDs(of: $0).union([$0]) } ?? []
    return depthFirst().filter {
      $0.lifecycle == .active && !$0.hidden && $0.kind == kind && !excluded.contains($0.id)
    }
  }

  /// Every category in display order, parents before their children.
  func depthFirst() -> [LedgerCategory] {
    var result: [LedgerCategory] = []
    var pending = Array(rootIDs.reversed())
    while let id = pending.popLast() {
      guard let category = byID[id] else { continue }
      result.append(category)
      pending.append(contentsOf: (childIDs[id] ?? []).reversed())
    }
    return result
  }

  /// Adds each category's own value to itself and to every ancestor exactly once.
  /// Values keyed by unknown categories are ignored.
  func rollUp<Value>(
    _ own: [String: Value], zero: Value, combine: (Value, Value) -> Value
  ) -> [String: Value] {
    var totals: [String: Value] = [:]
    for (id, value) in own where byID[id] != nil {
      var cursor: String? = id
      while let current = cursor {
        totals[current] = combine(totals[current] ?? zero, value)
        cursor = parentOf[current]
      }
    }
    return totals
  }

  /// Moves `id` by `offset` among its siblings and renumbers them 0, 1, 2, …
  /// Returns only the categories whose display order changed.
  func reordered(_ id: String, by offset: Int) -> [LedgerCategory] {
    guard let category = byID[id] else { return [] }
    var siblings = children(of: parentOf[id])
    guard let index = siblings.firstIndex(where: { $0.id == category.id }) else { return [] }
    let target = min(max(index + offset, 0), siblings.count - 1)
    guard target != index else { return [] }
    siblings.insert(siblings.remove(at: index), at: target)
    return siblings.enumerated().compactMap { position, sibling in
      guard sibling.displayOrder != position else { return nil }
      return try? sibling.with(displayOrder: position)
    }
  }

  /// Why `id` cannot be restored right now, or nil when it can.
  func restoreBlocker(for id: String) -> String? {
    guard let category = byID[id], category.lifecycle == .tombstoned else { return nil }
    guard let parentID = category.parentID else { return nil }
    guard let parent = byID[parentID] else { return "Its parent category no longer exists." }
    if parent.lifecycle != .active { return "Restore “\(parent.name)” first." }
    if parent.hidden { return "Show “\(parent.name)” first." }
    return nil
  }

  /// Why `id` cannot be hidden or closed right now, or nil when it can.
  func closeBlocker(for id: String) -> String? {
    let active = descendantIDs(of: id).compactMap { byID[$0] }.filter { $0.lifecycle == .active }
    guard let first = active.min(by: Self.order) else { return nil }
    return active.count == 1
      ? "Close “\(first.name)” first."
      : "Close its \(active.count) open subcategories first."
  }
}

/// Transactions per category: the category's own and those of all its subcategories.
struct CategoryUsage: Equatable {
  var direct = 0
  var total = 0

  static func counts(
    _ transactions: [LedgerTransactionSnapshot], in tree: CategoryTree
  ) -> [String: CategoryUsage] {
    var own: [String: Int] = [:]
    for transaction in transactions where transaction.currentRevision.lifecycle == .active {
      if let id = transaction.currentRevision.draft.categoryID { own[id, default: 0] += 1 }
    }
    let totals = tree.rollUp(own, zero: 0, combine: +)
    var result: [String: CategoryUsage] = [:]
    for (id, total) in totals { result[id] = CategoryUsage(direct: own[id] ?? 0, total: total) }
    return result
  }
}

extension LedgerCategory {
  func with(
    name: String? = nil, lifecycle: LedgerLifecycleState? = nil, parentID: String?? = nil,
    displayOrder: Int? = nil, hidden: Bool? = nil
  ) throws -> LedgerCategory {
    try LedgerCategory(
      id: id, name: name ?? self.name, kind: kind, origin: origin,
      lifecycle: lifecycle ?? self.lifecycle, parentID: parentID ?? self.parentID,
      displayOrder: displayOrder ?? self.displayOrder, hidden: hidden ?? self.hidden)
  }
}
