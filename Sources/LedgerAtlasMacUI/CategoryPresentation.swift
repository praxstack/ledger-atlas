import Foundation
import LedgerCore

enum CategoryPresentation {
  static func label(_ category: LedgerCategory, in categories: [LedgerCategory]) -> String {
    let byID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
    var names = [category.name]
    var parentID = category.parentID
    var visited: Set<String> = [category.id]
    while let id = parentID, visited.insert(id).inserted, let parent = byID[id] {
      names.append(parent.name)
      parentID = parent.parentID
    }
    return names.reversed().joined(separator: " › ")
  }
}
