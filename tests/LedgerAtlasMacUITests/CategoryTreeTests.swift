import Foundation
import LedgerCore
import Testing

@testable import LedgerAtlasMacUI

private let origin = try! LedgerOrigin(id: String(repeating: "7", count: 64), label: "tests")

private func id(_ key: String) -> String {
  let hex = key.unicodeScalars.map { String(format: "%02x", $0.value) }.joined()
  return try! StableLedgerID.category(
    origin: origin, localKey: String((hex + String(repeating: "0", count: 64)).prefix(64)))
}

private func category(
  _ key: String, parent: String? = nil, order: Int = 0, kind: LedgerCategoryKind = .expense,
  lifecycle: LedgerLifecycleState = .active, hidden: Bool = false
) -> LedgerCategory {
  try! LedgerCategory(
    id: id(key), name: key, kind: kind, origin: origin, lifecycle: lifecycle,
    parentID: parent.map(id), displayOrder: order, hidden: hidden)
}

/// Food › Dining › Cafes, Food › Groceries, Travel; Salary is income.
private let sample = [
  category("Travel", order: 1),
  category("Food", order: 0),
  category("Groceries", parent: "Food", order: 1),
  category("Dining", parent: "Food", order: 0),
  category("Cafes", parent: "Dining"),
  category("Salary", order: 2, kind: .income),
]

@Test func categoryTreeOrdersRootsChildrenAndDepthFirst() {
  let tree = CategoryTree(sample)
  #expect(tree.children(of: nil).map(\.name) == ["Food", "Travel", "Salary"])
  #expect(tree.children(of: id("Food")).map(\.name) == ["Dining", "Groceries"])
  #expect(tree.depthFirst().map(\.name) == ["Food", "Dining", "Cafes", "Groceries", "Travel", "Salary"])
  #expect(tree.path(to: id("Cafes")).map(\.name) == ["Food", "Dining", "Cafes"])
  #expect(tree.depth(of: id("Cafes")) == 2)
  #expect(tree.label(for: id("Cafes")) == "Food › Dining › Cafes")
  #expect(CategoryPresentation.label(sample[4], in: sample) == "Food › Dining › Cafes")
  #expect(tree.descendantIDs(of: id("Food")) == [id("Dining"), id("Groceries"), id("Cafes")])
}

@Test func categoryTreeHandlesAThousandLevelsWithoutRecursion() {
  var deep = [category("L0")]
  for level in 1..<1_000 { deep.append(category("L\(level)", parent: "L\(level - 1)")) }
  let tree = CategoryTree(deep.shuffled())
  #expect(tree.depth(of: id("L999")) == 999)
  #expect(tree.descendantIDs(of: id("L0")).count == 999)
  #expect(tree.depthFirst().map(\.name) == deep.map(\.name))
  let totals = tree.rollUp([id("L999"): 1], zero: 0, combine: +)
  #expect(totals.count == 1_000)
  #expect(totals.values.allSatisfy { $0 == 1 })
}

@Test func categoryTreeKeepsOrphansAndBreaksCyclesSoEveryCategoryAppearsOnce() {
  let damaged = [
    category("A", parent: "B"),
    category("B", parent: "A"),
    category("Orphan", parent: "Missing"),
    category("Child", parent: "A"),
  ]
  let tree = CategoryTree(damaged)
  let listed = tree.depthFirst().map(\.name)
  #expect(listed.sorted() == ["A", "B", "Child", "Orphan"])
  #expect(Set(listed).count == listed.count)
  #expect(tree.children(of: nil).map(\.name).contains("Orphan"))
  // The cycle is cut once, so paths and roll-ups terminate.
  #expect(tree.path(to: id("Child")).count <= 3)
  let totals = tree.rollUp([id("Child"): 1, id("A"): 1, id("B"): 1], zero: 0, combine: +)
  #expect(totals.values.allSatisfy { $0 <= 3 })
  #expect(totals.values.max() == 3)
}

@Test func rollUpCountsEachValueOnceAtEveryAncestor() {
  let tree = CategoryTree(sample)
  let own = [id("Food"): 1, id("Dining"): 2, id("Cafes"): 4, id("Groceries"): 8, "unknown": 100]
  let totals = tree.rollUp(own, zero: 0, combine: +)
  #expect(totals[id("Cafes")] == 4)
  #expect(totals[id("Dining")] == 6)
  #expect(totals[id("Groceries")] == 8)
  #expect(totals[id("Food")] == 15)
  #expect(totals[id("Travel")] == nil)
  // Roots add up to the sum of all known own values: nothing counted twice.
  let rootSum = tree.children(of: nil).compactMap { totals[$0.id] }.reduce(0, +)
  #expect(rootSum == 15)
}

@Test func reorderRenumbersSiblingsAndReturnsOnlyChangedOnes() {
  let tree = CategoryTree(sample)
  let movedUp = tree.reordered(id("Groceries"), by: -1)
  #expect(Set(movedUp.map(\.name)) == ["Groceries", "Dining"])
  #expect(movedUp.first { $0.name == "Groceries" }?.displayOrder == 0)
  #expect(movedUp.first { $0.name == "Dining" }?.displayOrder == 1)
  #expect(tree.reordered(id("Dining"), by: -1).isEmpty)
  #expect(tree.reordered(id("Salary"), by: 5).isEmpty)
  let reordered = CategoryTree(sample.map { original in movedUp.first { $0.id == original.id } ?? original })
  #expect(reordered.children(of: id("Food")).map(\.name) == ["Groceries", "Dining"])
  // Only the order changed; links by id stay intact.
  #expect(reordered.path(to: id("Cafes")).map(\.name) == ["Food", "Dining", "Cafes"])
}

@Test func validParentsExcludeSelfDescendantsOtherKindsAndUnavailableCategories() {
  let categories = sample + [
    category("Closed", lifecycle: .tombstoned), category("Secret", hidden: true),
  ]
  let tree = CategoryTree(categories)
  let forDining = tree.validParents(for: .expense, movingID: id("Dining")).map(\.name)
  #expect(forDining == ["Food", "Groceries", "Travel"])
  #expect(tree.validParents(for: .income).map(\.name) == ["Salary"])
}

@Test func lifecycleBlockersMatchTheStoreRules() {
  let categories = [
    category("Food"),
    category("Dining", parent: "Food"),
    category("Old", parent: "Food", lifecycle: .tombstoned),
    category("Archive", lifecycle: .tombstoned),
    category("Kept", parent: "Archive", lifecycle: .tombstoned),
  ]
  let tree = CategoryTree(categories)
  #expect(tree.closeBlocker(for: id("Food")) == "Close “Dining” first.")
  #expect(tree.closeBlocker(for: id("Dining")) == nil)
  #expect(tree.restoreBlocker(for: id("Old")) == nil)
  #expect(tree.restoreBlocker(for: id("Kept")) == "Restore “Archive” first.")
  #expect(tree.restoreBlocker(for: id("Archive")) == nil)
}

@Test func renameMoveHideCloseAndRestoreKeepTheCategoryID() throws {
  let cafes = sample[4]
  let renamed = try cafes.with(name: "Coffee")
  let moved = try renamed.with(parentID: .some(id("Food")))
  let hidden = try moved.with(hidden: true)
  let closed = try hidden.with(lifecycle: .tombstoned)
  let restored = try closed.with(lifecycle: .active, hidden: false)
  for version in [renamed, moved, hidden, closed, restored] {
    #expect(version.id == cafes.id)
    #expect(version.kind == cafes.kind)
    #expect(version.origin == cafes.origin)
  }
  #expect(try moved.with(parentID: .some(nil)).parentID == nil)
  #expect(moved.parentID == id("Food"))
}
