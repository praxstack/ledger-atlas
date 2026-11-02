import Foundation
import Testing

@testable import LedgerCore

private let origin = try! LedgerOrigin(id: String(repeating: "8", count: 64), label: "synthetic")
private let zone = try! SourceTimeZone(fixedOffsetSeconds: 19_800)

private func key(_ seed: String) -> String {
  let hex = seed.unicodeScalars.map { String(format: "%02x", $0.value) }.joined()
  return String((hex + String(repeating: "0", count: 64)).prefix(64))
}

private struct Fixture {
  let wallet: LedgerAccount
  let savings: LedgerAccount
  let food: LedgerCategory
  let snacks: LedgerCategory
  let tag: LedgerTag
  let content: LedgerXLSXExchange.Content

  init() throws {
    wallet = try LedgerAccount(
      id: StableLedgerID.account(origin: origin, localKey: key("wallet")), name: "Wallet",
      currencyUnit: "INR", origin: origin)
    savings = try LedgerAccount(
      id: StableLedgerID.account(origin: origin, localKey: key("savings")), name: "Savings",
      currencyUnit: "INR", origin: origin)
    // Ids chosen so the child sorts before its parent: the plan must still create the
    // parent first.
    snacks = try LedgerCategory(
      id: String(repeating: "1", count: 64), name: "Snacks", kind: .expense, origin: origin,
      parentID: String(repeating: "f", count: 64))
    food = try LedgerCategory(
      id: String(repeating: "f", count: 64), name: "Food", kind: .expense, origin: origin)
    tag = try LedgerTag(
      id: StableLedgerID.tag(origin: origin, localKey: key("tag")), name: "trip", origin: origin)
    let when = try SourceTemporal(
      resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 4, day: 1)),
      in: zone, precision: .day)
    func amount(_ literal: String) throws -> CurrencyAmount {
      try CurrencyAmount(unitCode: "INR", amount: ExactDecimal(literal))
    }
    func transaction(
      _ seed: String, _ draft: LedgerTransactionDraft, lifecycle: LedgerLifecycleState = .active,
      tags: [String] = []
    ) throws -> LedgerXLSXExchange.Transaction {
      LedgerXLSXExchange.Transaction(
        id: try StableLedgerID.transaction(origin: origin, localKey: key(seed)), draft: draft,
        lifecycle: lifecycle, tags: try LedgerTagLinks(tags))
    }
    let wallet = self.wallet
    let savings = self.savings
    content = LedgerXLSXExchange.Content(
      accounts: [wallet, savings], categories: [snacks, food], tags: [tag],
      transactions: [
        try transaction(
          "chips",
          LedgerTransactionDraft(
            effects: [LedgerTransactionEffect(accountID: wallet.id, direction: .decrease, amount: amount("40"))],
            categoryID: snacks.id, kind: .expense, occurredAt: when, note: "chips", origin: origin),
          tags: [tag.id]),
        try transaction(
          "move",
          LedgerTransactionDraft(
            effects: [
              LedgerTransactionEffect(accountID: wallet.id, direction: .decrease, amount: amount("500")),
              LedgerTransactionEffect(accountID: savings.id, direction: .increase, amount: amount("500")),
            ], categoryID: nil, kind: .transfer, occurredAt: when, origin: origin)),
        try transaction(
          "gone",
          LedgerTransactionDraft(
            effects: [LedgerTransactionEffect(accountID: wallet.id, direction: .decrease, amount: amount("1"))],
            categoryID: nil, kind: .expense, occurredAt: when, origin: origin),
          lifecycle: .tombstoned),
      ])
  }
}

@Test func planForAnEmptyLedgerAddsEverythingParentsFirst() throws {
  let fixture = try Fixture()
  let plan = LedgerXLSXImportPlan(content: fixture.content, existing: .init())
  #expect(plan.canApply)
  #expect(plan.accounts.count == 2)
  #expect(plan.categories.map(\.name) == ["Food", "Snacks"])
  #expect(plan.tags == [fixture.tag])
  #expect(plan.skippedDeletedTransactions == 1)
  #expect(plan.transactions.count == 2)
  let importOrigin = try LedgerXLSXImportPlan.origin()
  #expect(importOrigin.label == "xlsx-import")
  #expect(plan.transactions.allSatisfy { $0.draft.origin == importOrigin })
  let transfer = try #require(plan.transactions.first { $0.draft.kind == .transfer })
  #expect(transfer.draft.effects.count == 2)  // both legs stay in one transaction
  #expect(plan.transactions.first { $0.draft.kind == .expense }?.tags.tagIDs == [fixture.tag.id])
  #expect(plan.summary["Transactions"] == .init(added: 2, unchanged: 0))
}

@Test func reimportingIntoTheSourceLedgerChangesNothing() throws {
  let fixture = try Fixture()
  let existing = LedgerXLSXImportPlan.Existing(
    accounts: fixture.content.accounts, categories: fixture.content.categories,
    tags: fixture.content.tags, transactions: fixture.content.transactions)
  let plan = LedgerXLSXImportPlan(content: fixture.content, existing: existing)
  #expect(plan.canApply)
  #expect(plan.isEmpty)
  #expect(plan.summary["Accounts"] == .init(added: 0, unchanged: 2))
  #expect(plan.summary["Transactions"] == .init(added: 0, unchanged: 2))
}

@Test func applyingAPlanTwiceAddsNothingTheSecondTime() throws {
  let fixture = try Fixture()
  let first = LedgerXLSXImportPlan(content: fixture.content, existing: .init())
  // What the ledger holds after applying `first`.
  let stored = try first.transactions.map { new in
    LedgerXLSXExchange.Transaction(
      id: try StableLedgerID.transaction(origin: new.draft.origin, localKey: new.idempotencyKey),
      draft: new.draft, tags: new.tags)
  }
  let second = LedgerXLSXImportPlan(
    content: fixture.content,
    existing: .init(
      accounts: first.accounts, categories: first.categories, tags: first.tags,
      transactions: stored))
  #expect(second.isEmpty)
  #expect(second.canApply)
}

@Test func editedRowsGetNewKeysAndNeverOverwrite() throws {
  let fixture = try Fixture()
  let original = fixture.content.transactions[0]
  let editedDraft = try LedgerTransactionDraft(
    effects: original.draft.effects, categoryID: original.draft.categoryID,
    kind: original.draft.kind, occurredAt: original.draft.occurredAt, note: "crisps",
    origin: original.draft.origin)
  var edited = original
  edited.draft = editedDraft
  #expect(
    LedgerXLSXImportPlan.idempotencyKey(for: original)
      == LedgerXLSXImportPlan.idempotencyKey(for: original))
  #expect(
    LedgerXLSXImportPlan.idempotencyKey(for: original)
      != LedgerXLSXImportPlan.idempotencyKey(for: edited))
  #expect(LedgerXLSXImportPlan.idempotencyKey(for: original).count == 64)

  // The same id edited in the spreadsheet is a conflict against the ledger it came from.
  var content = fixture.content
  content.transactions[0] = edited
  let plan = LedgerXLSXImportPlan(
    content: content,
    existing: .init(
      accounts: fixture.content.accounts, categories: fixture.content.categories,
      tags: fixture.content.tags, transactions: fixture.content.transactions))
  #expect(!plan.canApply)
  #expect(plan.conflicts.contains { $0.sheet == "Transactions" })
}

@Test func recordsThatDifferFromTheLedgerBlockTheImport() throws {
  let fixture = try Fixture()
  let renamed = try LedgerAccount(
    id: fixture.wallet.id, name: "Old wallet", currencyUnit: "INR", origin: origin)
  let plan = LedgerXLSXImportPlan(
    content: fixture.content, existing: .init(accounts: [renamed]))
  #expect(!plan.canApply)
  #expect(plan.conflicts.count == 1)
  #expect(plan.conflicts[0].sheet == "Accounts")
  #expect(plan.conflicts[0].message.contains("Wallet"))
}

@Test func newRowsOnAnAccountDeletedHereBlockTheImport() throws {
  let fixture = try Fixture()
  let deleted = try LedgerAccount(
    id: fixture.wallet.id, name: "Wallet", currencyUnit: "INR", origin: origin,
    lifecycle: .tombstoned)
  var content = fixture.content
  content.accounts = [deleted, fixture.savings]
  let plan = LedgerXLSXImportPlan(content: content, existing: .init(accounts: [deleted]))
  #expect(!plan.canApply)
  #expect(plan.conflicts.allSatisfy { $0.message.contains("deleted in this ledger") })
  #expect(plan.conflicts.count == 2)  // the expense and the transfer both use the wallet
}
