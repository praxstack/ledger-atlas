import LedgerCore
import Testing

@Suite("Ledger domain")
struct LedgerDomainTests {
  @Test("stable account IDs separate origin and local identity")
  func stableAccountIDsAreScoped() throws {
    let local = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
    let imported = try LedgerOrigin(
      id: String(repeating: "2", count: 64), label: "import",
      provenanceID: String(repeating: "a", count: 64))
    #expect(
      try StableLedgerID.account(origin: local, localKey: String(repeating: "c", count: 64))
        != StableLedgerID.account(origin: imported, localKey: String(repeating: "c", count: 64)))
    #expect(
      try StableLedgerID.account(origin: local, localKey: String(repeating: "c", count: 64))
        == StableLedgerID.account(origin: local, localKey: String(repeating: "c", count: 64)))
  }

  @Test("domain models reject malformed references and destructive links")
  func modelsFailClosed() throws {
    let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
    #expect(throws: LedgerDomainError.self) {
      try LedgerAccount(id: "not-an-id", name: "Cash", currencyUnit: "USD", origin: origin)
    }
    let transactionID = try StableLedgerID.transaction(
      origin: origin, localKey: String(repeating: "d", count: 64))
    #expect(throws: LedgerDomainError.invalidLink) {
      try StableLedgerID.link(
        fromTransactionID: transactionID, toTransactionID: transactionID, kind: .related)
    }
    #expect(throws: LedgerDomainError.invalidLink) {
      try LedgerTransactionLink(
        id: String(repeating: "b", count: 64),
        fromTransactionID: transactionID, toTransactionID: transactionID, kind: .related)
    }
    #expect(throws: LedgerDomainError.invalidIdentifier) {
      try StableLedgerID.account(origin: origin, localKey: String(repeating: "x", count: 4_097))
    }
  }

  @Test("transfer drafts require exactly two distinct account effects")
  func transfersHaveTwoEffects() throws {
    let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
    let first = String(repeating: "a", count: 64)
    let second = String(repeating: "b", count: 64)
    let amount = try CurrencyAmount(unitCode: "USD", amount: ExactDecimal("12.30"))
    let firstEffect = try LedgerTransactionEffect(
      accountID: first, direction: .decrease, amount: amount)
    let secondEffect = try LedgerTransactionEffect(
      accountID: second, direction: .increase, amount: amount)
    let when = try SourceTemporal(
      resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 1, day: 2)),
      in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .minute)

    _ = try LedgerTransactionDraft(
      effects: [firstEffect, secondEffect], categoryID: nil, kind: .transfer, occurredAt: when,
      origin: origin)
    #expect(throws: LedgerDomainError.invalidEffects) {
      try LedgerTransactionDraft(
        effects: [firstEffect], categoryID: nil, kind: .transfer, occurredAt: when, origin: origin)
    }
    #expect(throws: LedgerDomainError.invalidEffects) {
      try LedgerTransactionEffect(
        accountID: first, direction: .decrease,
        amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("-1")))
    }
    _ = try LedgerTransactionDraft(
      effects: [
        firstEffect,
        try LedgerTransactionEffect(
          accountID: second, direction: .increase,
          amount: CurrencyAmount(unitCode: "EUR", amount: ExactDecimal("11.00"))),
      ], categoryID: nil, kind: .transfer, occurredAt: when, origin: origin)
    #expect(throws: LedgerDomainError.invalidEffects) {
      try LedgerTransactionEffect(
        accountID: first, direction: .decrease,
        amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("0")))
    }
    #expect(throws: LedgerDomainError.invalidEffects) {
      try LedgerTransactionDraft(
        effects: [firstEffect], categoryID: nil, kind: .income, occurredAt: when, origin: origin)
    }
  }

  @Test("revisions and links require their stable identities")
  func derivedRelationshipsFailClosed() throws {
    let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
    let transactionID = try StableLedgerID.transaction(
      origin: origin, localKey: String(repeating: "d", count: 64))
    let accountID = String(repeating: "a", count: 64)
    let effect = try LedgerTransactionEffect(
      accountID: accountID, direction: .increase,
      amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("1")))
    let when = try SourceTemporal(
      resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 1, day: 2)),
      in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .minute)
    let draft = try LedgerTransactionDraft(
      effects: [effect], categoryID: nil, kind: .income, occurredAt: when, origin: origin)
    #expect(throws: LedgerDomainError.invalidRevision) {
      try LedgerTransactionRevision(
        id: String(repeating: "e", count: 64), transactionID: transactionID, revision: 1,
        predecessorID: nil, draft: draft, createdAt: UTCInstant(epochMilliseconds: 0))
    }
    #expect(throws: LedgerDomainError.invalidRevision) {
      try LedgerTransactionRevision(
        id: try StableLedgerID.revision(transactionID: transactionID, revision: 2),
        transactionID: transactionID, revision: 2, predecessorID: String(repeating: "e", count: 64),
        draft: draft, createdAt: UTCInstant(epochMilliseconds: 0))
    }
    #expect(throws: LedgerDomainError.invalidLink) {
      try LedgerTransactionLink(
        id: String(repeating: "f", count: 64), fromTransactionID: transactionID,
        toTransactionID: String(repeating: "b", count: 64), kind: .related)
    }
  }
}
