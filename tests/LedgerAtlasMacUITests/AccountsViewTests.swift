import Foundation
import LedgerCore
import LedgerStore
import Testing

@testable import LedgerAtlasMacUI

private func account(_ key: Character, order: Int = 0, group: String? = nil) throws -> LedgerAccount {
  let origin = try LedgerOrigin.macNative()
  return try LedgerAccount(
    id: try StableLedgerID.account(origin: origin, localKey: String(repeating: key, count: 64)),
    name: "Account \(key)", currencyUnit: "INR", origin: origin, groupID: group,
    displayOrder: order)
}

@Test func reorderingAccountsWithDefaultOrdersNumbersTheSection() throws {
  let members = AccountsView.sortedAccounts([try account("a"), try account("b"), try account("c")])
  #expect(members.map(\.name) == ["Account a", "Account b", "Account c"])

  let changed = AccountsView.reordered(members, moving: members[2].id, by: -1)

  // a keeps slot 0; c and b take slots 1 and 2, so only they are saved.
  #expect(Dictionary(uniqueKeysWithValues: changed.map { ($0.name, $0.displayOrder) })
    == ["Account b": 2, "Account c": 1])
  let applied = AccountsView.sortedAccounts(
    members.map { member in changed.first { $0.id == member.id } ?? member })
  #expect(applied.map(\.name) == ["Account a", "Account c", "Account b"])
}

@Test func reorderingAtTheEdgeChangesNothing() throws {
  let members = [try account("a", order: 0), try account("b", order: 1)]
  #expect(AccountsView.reordered(members, moving: members[0].id, by: -1).isEmpty)
  #expect(AccountsView.reordered(members, moving: members[1].id, by: 1).isEmpty)
  #expect(AccountsView.reordered(members, moving: String(repeating: "f", count: 64), by: 1).isEmpty)
}

@Test func reorderingGroupsSwapsNeighboursOnly() throws {
  let groups = try [
    LedgerAccountGroup(id: String(repeating: "1", count: 64), name: "Cash", displayOrder: 0),
    LedgerAccountGroup(id: String(repeating: "2", count: 64), name: "Bank", displayOrder: 1),
    LedgerAccountGroup(id: String(repeating: "3", count: 64), name: "Cards", displayOrder: 2),
  ]
  let changed = AccountsView.reordered(groups, moving: groups[0].id, by: 1)
  #expect(Set(changed.map(\.name)) == ["Cash", "Bank"])
  #expect(changed.first { $0.name == "Cash" }?.displayOrder == 1)
  #expect(changed.first { $0.name == "Bank" }?.displayOrder == 0)
}

@MainActor
@Test func groupedAccountManagementPersistsAcrossReopen() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let destination = directory.appendingPathComponent("accounts.sqlite")
  let suite = "LedgerAtlasMacUITests.accounts.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let bookmarks = SecurityScopedBookmarkStore(
    defaults: defaults, makeBookmark: { Data($0.path.utf8) },
    resolveBookmark: { URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)) })

  let journey = LedgerJourney()
  let created = await LedgerAtlasRootView.performLedgerLifecycle(
    .create, at: destination, bookmarkStore: bookmarks, widgetPublisher: .init(write: { _ in }),
    journey: journey, session: LedgerSession(testingScopeStarter: { _ in true }),
    scopeStarter: { _ in true }, scopeStopper: { _ in })
  #expect(created.kind == .created)
  try journey.performBeginEditing()
  let origin = try LedgerOrigin.macNative()

  let daily = try LedgerAccountGroup(id: String(repeating: "1", count: 64), name: "Daily")
  let borrowed = try LedgerAccountGroup(
    id: String(repeating: "2", count: 64), name: "Borrowed", displayOrder: 1)
  try journey.createAccountGroup(daily)
  try journey.createAccountGroup(borrowed)
  let cash = try account("a", group: daily.id)
  let bank = try account("b", group: daily.id)
  let loan = try LedgerAccount(
    id: try StableLedgerID.account(origin: origin, localKey: String(repeating: "c", count: 64)),
    name: "Home loan", currencyUnit: "INR", origin: origin, groupID: borrowed.id, variant: .loan)
  let hidden = try LedgerAccount(
    id: try StableLedgerID.account(origin: origin, localKey: String(repeating: "d", count: 64)),
    name: "Old wallet", currencyUnit: "INR", origin: origin, hidden: true)
  for item in [cash, bank, loan, hidden] { try journey.createAccount(item) }
  let now = UTCInstant(epochMilliseconds: UTCInstant.currentEpochMilliseconds())
  _ = try journey.createNativeTransaction(
    amountLiteral: "1000", kind: .income, accountID: bank.id, categoryID: nil, note: nil,
    createdAt: now)
  _ = try journey.createNativeTransaction(
    amountLiteral: "50000", kind: .expense, accountID: loan.id, categoryID: nil, note: nil,
    createdAt: UTCInstant(epochMilliseconds: now.epochMilliseconds + 1))
  _ = try journey.createNativeTransaction(
    amountLiteral: "70", kind: .income, accountID: hidden.id, categoryID: nil, note: nil,
    createdAt: UTCInstant(epochMilliseconds: now.epochMilliseconds + 2))

  // Move "Account b" above "Account a", and "Borrowed" above "Daily".
  let members = AccountsView.sortedAccounts(
    try #require(journey.snapshot).accounts.filter { $0.groupID == daily.id })
  for revised in AccountsView.reordered(members, moving: bank.id, by: -1) {
    try journey.updateAccount(revised)
  }
  let groups = AccountsView.sortedGroups(try #require(journey.snapshot).accountGroups)
  for revised in AccountsView.reordered(groups, moving: borrowed.id, by: -1) {
    try journey.updateAccountGroup(revised)
  }

  // Reopen from disk with a fresh journey and session.
  let reopened = LedgerJourney()
  let outcome = await LedgerAtlasRootView.performLedgerLifecycle(
    .open, at: destination, bookmarkStore: bookmarks, widgetPublisher: .init(write: { _ in }),
    journey: reopened, session: LedgerSession(testingScopeStarter: { _ in true }),
    scopeStarter: { _ in true }, scopeStopper: { _ in })
  #expect(outcome.kind == .opened)
  let snapshot = try #require(reopened.snapshot)
  #expect(AccountsView.sortedGroups(snapshot.accountGroups).map(\.name) == ["Borrowed", "Daily"])
  #expect(
    AccountsView.sortedAccounts(snapshot.accounts.filter { $0.groupID == daily.id }).map(\.name)
      == ["Account b", "Account a"])
  #expect(snapshot.accounts.first { $0.id == loan.id }?.variant == .loan)
  #expect(snapshot.accounts.first { $0.id == hidden.id }?.hidden == true)

  let sheet = try LedgerAccountBalanceSheet(
    accounts: snapshot.accounts, transactions: snapshot.transactions)
  #expect(sheet.balances[hidden.id]?.amount == (try ExactDecimal("70")))
  #expect(sheet.summaries.count == 1)
  #expect(sheet.summaries[0].assets == (try ExactDecimal("1000")))
  #expect(sheet.summaries[0].liabilities == (try ExactDecimal("-50000")))
  #expect(sheet.summaries[0].net == (try ExactDecimal("-49000")))
  #expect(sheet.groupTotals[daily.id]?["INR"] == (try ExactDecimal("1000")))
  // The hidden wallet's 70 is in its own balance but in no total.
  #expect(sheet.groupTotals[nil] == nil)
}
