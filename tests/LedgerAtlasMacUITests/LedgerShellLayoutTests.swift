import Foundation
import LedgerCore
import Testing

@testable import LedgerAtlasMacUI

private let origin = try! LedgerOrigin(id: String(repeating: "6", count: 64), label: "tests")

@Test func sidebarSectionsListEveryScreenOnce() {
  let listed = AppDestination.SidebarSection.allCases.flatMap(\.destinations)
  #expect(listed.count == Set(listed).count, "a screen is listed twice")
  #expect(Set(listed) == Set(AppDestination.allCases), "a screen is missing from the sidebar")
  #expect(AppDestination.SidebarSection.money.destinations.first == .ledger)
}

@Test func sidebarSpeaksPlainNamesAndKeepsStableTitles() {
  #expect(AppDestination.ledger.sidebarTitle == "Transactions")
  #expect(AppDestination.ledger.title == "Ledger")
  #expect(AppDestination.recurrence.sidebarTitle == "Recurring")
  #expect(AppDestination.ledger.accessibilityLabel == "Transactions")
  let names = AppDestination.allCases.map(\.sidebarTitle)
  #expect(names.count == Set(names).count)
}

@Test func sidebarAccountsFollowGroupOrderAndHideClosedOnes() throws {
  func id(_ seed: Character) -> String { String(repeating: seed, count: 64) }
  let cards = try LedgerAccountGroup(id: id("c"), name: "Cards", displayOrder: 1)
  let bank = try LedgerAccountGroup(id: id("b"), name: "Bank", displayOrder: 0)
  let accounts = [
    try LedgerAccount(
      id: id("1"), name: "Credit card", currencyUnit: "INR", origin: origin, groupID: cards.id,
      variant: .loan),
    try LedgerAccount(
      id: id("2"), name: "Savings", currencyUnit: "INR", origin: origin, groupID: bank.id,
      displayOrder: 1),
    try LedgerAccount(
      id: id("3"), name: "Everyday", currencyUnit: "INR", origin: origin, groupID: bank.id),
    try LedgerAccount(id: id("4"), name: "Wallet", currencyUnit: "INR", origin: origin),
    try LedgerAccount(
      id: id("5"), name: "Old", currencyUnit: "INR", origin: origin, lifecycle: .tombstoned),
    try LedgerAccount(id: id("7"), name: "Hidden", currencyUnit: "INR", origin: origin, hidden: true),
  ]
  let listed = LedgerSidebarAccount.list(accounts: accounts, groups: [cards, bank], transactions: [])
  #expect(listed.map(\.name) == ["Everyday", "Savings", "Credit card", "Wallet"])
  #expect(listed.first?.groupName == "Bank")
  #expect(listed.first?.balance?.unitCode == "INR")
  #expect(listed.first(where: { $0.name == "Credit card" })?.isAsset == false)
}
