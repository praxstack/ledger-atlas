import Foundation
import LedgerAtlasMacUI
import Testing

@Test func destinationsHaveStableIndependentNamesAndAccessibilityCopy() {
  let destinations = AppDestination.allCases

  #expect(destinations.contains(.ledger))
  #expect(destinations.contains(.importReview))
  #expect(destinations.contains(.backupRestore))
  #expect(destinations.contains(.search))
  #expect(destinations.count >= 13)
  #expect(Set(destinations.map(\.title)).count == destinations.count)

  for destination in destinations {
    #expect(!destination.accessibilityLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(!destination.accessibilityHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }
}

@Test func overviewIsTheDeterministicDefaultSelection() {
  #expect(AppDestination.defaultSelection == .overview)
}
