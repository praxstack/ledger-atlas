import LedgerCore
import Testing

@Suite("Ledger annotations: tags, templates, memos")
struct LedgerAnnotationTests {
  let origin: LedgerOrigin
  let cash = String(repeating: "a", count: 64)
  let bank = String(repeating: "b", count: 64)
  let food = String(repeating: "c", count: 64)

  init() throws {
    origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  }

  private func id(_ key: Character, _ make: (LedgerOrigin, String) throws -> String) throws
    -> String
  {
    try make(origin, String(repeating: key, count: 64))
  }

  private func amount(_ literal: String, _ unit: String = "INR") throws -> CurrencyAmount {
    try CurrencyAmount(unitCode: unit, amount: ExactDecimal(literal))
  }

  private func when() throws -> SourceTemporal {
    try SourceTemporal(
      resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 3, day: 4)),
      in: SourceTimeZone(fixedOffsetSeconds: 19_800), precision: .minute)
  }

  // MARK: Tags

  @Test("stable IDs for tags, templates and memos are scoped by kind and origin")
  func stableIDsAreScoped() throws {
    let key = String(repeating: "d", count: 64)
    let other = try LedgerOrigin(id: String(repeating: "2", count: 64), label: "import")
    let ids = [
      try StableLedgerID.tag(origin: origin, localKey: key),
      try StableLedgerID.transactionTemplate(origin: origin, localKey: key),
      try StableLedgerID.memo(origin: origin, localKey: key),
      try StableLedgerID.tag(origin: other, localKey: key),
      try StableLedgerID.category(origin: origin, localKey: key),
    ]
    #expect(Set(ids).count == ids.count)
    #expect(ids.allSatisfy(CanonicalIdentifier.isValid))
    #expect(try StableLedgerID.tag(origin: origin, localKey: key) == ids[0])
    #expect(throws: LedgerDomainError.invalidIdentifier) {
      try StableLedgerID.memo(origin: origin, localKey: "short")
    }
  }

  @Test("tag names are bounded, trimmed and free of control characters")
  func tagNamesAreValidated() throws {
    let tagID = try id("d", StableLedgerID.tag)
    _ = try LedgerTag(id: tagID, name: "Trip: Goa 2026", origin: origin)
    _ = try LedgerTag(id: tagID, name: "👥", origin: origin)
    for bad in ["", " food", "food ", "a\nb", "tab\there", String(repeating: "x", count: 65)] {
      #expect(throws: LedgerAnnotationError.invalidName) {
        try LedgerTag(id: tagID, name: bad, origin: origin)
      }
    }
    #expect(throws: LedgerAnnotationError.invalidIdentifier) {
      try LedgerTag(id: "nope", name: "food", origin: origin)
    }
  }

  @Test("active tag names are unique ignoring case and Unicode composition")
  func activeTagNamesAreUnique() throws {
    let first = try LedgerTag(id: try id("d", StableLedgerID.tag), name: "Café", origin: origin)
    // "Cafe" + combining acute accent: the same name typed another way.
    let decomposed = try LedgerTag(
      id: try id("e", StableLedgerID.tag), name: "CAFE\u{0301}", origin: origin)
    #expect(first.nameKey == decomposed.nameKey)
    #expect(throws: LedgerAnnotationError.duplicateActiveTagName) {
      try LedgerTag.validateActiveNamesAreUnique([first, decomposed])
    }
    // A tombstoned tag frees its name for reuse.
    try LedgerTag.validateActiveNamesAreUnique([try first.tombstoned(), decomposed])
    let different = try LedgerTag(
      id: try id("f", StableLedgerID.tag), name: "Cafeteria", origin: origin)
    try LedgerTag.validateActiveNamesAreUnique([first, different])
  }

  @Test("renaming keeps the tag's identity, and tombstoned tags cannot change")
  func renameKeepsIdentity() throws {
    let tag = try LedgerTag(id: try id("d", StableLedgerID.tag), name: "food", origin: origin)
    let renamed = try tag.renamed("groceries")
    #expect(renamed.id == tag.id)
    #expect(renamed.name == "groceries")
    let gone = try renamed.tombstoned()
    #expect(gone.lifecycle == .tombstoned)
    #expect(throws: LedgerAnnotationError.tombstoned) { try gone.renamed("again") }
    #expect(throws: LedgerAnnotationError.tombstoned) { try gone.tombstoned() }
  }

  @Test("tag links are sorted sets of identifiers and carry forward on corrections")
  func tagLinksCarryForward() throws {
    let a = try id("d", StableLedgerID.tag)
    let b = try id("e", StableLedgerID.tag)
    let links = try LedgerTagLinks([b, a])
    #expect(links == (try LedgerTagLinks([a, b])))
    #expect(links.tagIDs == [a, b].sorted())
    #expect(throws: LedgerAnnotationError.invalidIdentifier) { try LedgerTagLinks([a, a]) }
    #expect(throws: LedgerAnnotationError.invalidIdentifier) { try LedgerTagLinks(["food"]) }
    #expect(links.carriedForward(replacing: nil) == links)
    #expect(links.carriedForward(replacing: .empty) == .empty)
  }

  @Test("new links must point at active tags; existing links survive a tombstone")
  func newLinksNeedActiveTags() throws {
    let live = try LedgerTag(id: try id("d", StableLedgerID.tag), name: "food", origin: origin)
    let retired = try LedgerTag(
      id: try id("e", StableLedgerID.tag), name: "old", origin: origin, lifecycle: .tombstoned)
    let catalog = [live.id: live, retired.id: retired]

    try LedgerTagLinks([live.id]).validateNewLinks(tags: catalog)
    #expect(throws: LedgerAnnotationError.tombstoned) {
      try LedgerTagLinks([retired.id]).validateNewLinks(tags: catalog)
    }
    #expect(throws: LedgerAnnotationError.invalidIdentifier) {
      try LedgerTagLinks([try id("f", StableLedgerID.tag)]).validateNewLinks(tags: catalog)
    }
    // A correction that keeps an already-linked retired tag is fine.
    let previous = try LedgerTagLinks([retired.id])
    try LedgerTagLinks([live.id, retired.id]).validateNewLinks(previous: previous, tags: catalog)
  }

  // MARK: Templates

  @Test("an expense template instantiates into an ordinary draft with exact amounts")
  func expenseTemplateInstantiates() throws {
    let tags = try LedgerTagLinks([try id("d", StableLedgerID.tag)])
    let template = try LedgerTransactionTemplate(
      id: try id("1", StableLedgerID.transactionTemplate), name: "Milk", kind: .expense,
      categoryID: food, amount: try amount("56.10"), note: "Morning milk", accountID: cash,
      tags: tags, origin: origin)

    let draft = try template.instantiate(occurredAt: try when(), origin: origin)
    #expect(draft.kind == .expense)
    #expect(draft.categoryID == food)
    #expect(draft.note == "Morning milk")
    #expect(draft.effects.count == 1)
    #expect(draft.effects[0].accountID == cash)
    #expect(draft.effects[0].direction == .decrease)
    #expect(draft.effects[0].amount.amount == (try ExactDecimal("56.10")))
    #expect(draft.effects[0].amount.unitCode == "INR")
    #expect(template.tags == tags)
  }

  @Test("a transfer template keeps both accounts and has no category")
  func transferTemplateInstantiates() throws {
    let template = try LedgerTransactionTemplate(
      id: try id("1", StableLedgerID.transactionTemplate), name: "Top up cash", kind: .transfer,
      categoryID: nil, amount: try amount("2000"), accountID: bank, counterAccountID: cash,
      origin: origin)
    let draft = try template.instantiate(occurredAt: try when(), origin: origin)
    #expect(draft.kind == .transfer)
    #expect(
      Set(draft.effects.map { "\($0.accountID):\($0.direction.rawValue)" })
        == ["\(bank):decrease", "\(cash):increase"])

    #expect(throws: LedgerAnnotationError.invalidTemplate) {
      try LedgerTransactionTemplate(
        id: try id("2", StableLedgerID.transactionTemplate), name: "Bad", kind: .transfer,
        categoryID: food, amount: try amount("1"), accountID: bank, counterAccountID: cash,
        origin: origin)
    }
    #expect(throws: LedgerAnnotationError.invalidTemplate) {
      try LedgerTransactionTemplate(
        id: try id("2", StableLedgerID.transactionTemplate), name: "Bad", kind: .transfer,
        categoryID: nil, amount: try amount("1"), accountID: bank, counterAccountID: bank,
        origin: origin)
    }
  }

  @Test("templates reject adjustments, zero amounts and a counter account on expenses")
  func templateShapeIsValidated() throws {
    let templateID = try id("1", StableLedgerID.transactionTemplate)
    #expect(throws: LedgerAnnotationError.invalidTemplate) {
      try LedgerTransactionTemplate(
        id: templateID, name: "Fix", kind: .adjustment, categoryID: nil,
        amount: try amount("1"), accountID: cash, origin: origin)
    }
    #expect(throws: LedgerAnnotationError.invalidTemplate) {
      try LedgerTransactionTemplate(
        id: templateID, name: "Zero", kind: .expense, categoryID: food,
        amount: try amount("0"), accountID: cash, origin: origin)
    }
    #expect(throws: LedgerAnnotationError.invalidTemplate) {
      try LedgerTransactionTemplate(
        id: templateID, name: "Two", kind: .expense, categoryID: food,
        amount: try amount("1"), accountID: cash, counterAccountID: bank, origin: origin)
    }
    #expect(throws: LedgerAnnotationError.invalidName) {
      try LedgerTransactionTemplate(
        id: templateID, name: "", kind: .expense, categoryID: food,
        amount: try amount("1"), accountID: cash, origin: origin)
    }
  }

  @Test("capturing a transaction round-trips through instantiate")
  func captureRoundTrips() throws {
    let effect = try LedgerTransactionEffect(
      accountID: cash, direction: .increase, amount: try amount("1250.75", "USD"))
    let recorded = try LedgerTransactionDraft(
      effects: [effect], categoryID: food, kind: .income, occurredAt: try when(),
      note: "Refund", origin: origin)
    let tags = try LedgerTagLinks([try id("d", StableLedgerID.tag)])

    let template = try LedgerTransactionTemplate(
      capturing: recorded, tags: tags, id: try id("1", StableLedgerID.transactionTemplate),
      name: "Refund", origin: origin)
    #expect(template.kind == .income)
    #expect(template.amount == effect.amount)
    #expect(template.tags == tags)
    #expect(try template.instantiate(occurredAt: try when(), origin: origin) == recorded)

    let bankEffect = try LedgerTransactionEffect(
      accountID: bank, direction: .decrease, amount: try amount("5"))
    let cashEffect = try LedgerTransactionEffect(
      accountID: cash, direction: .increase, amount: try amount("5"))
    let transfer = try LedgerTransactionDraft(
      effects: [cashEffect, bankEffect], categoryID: nil, kind: .transfer,
      occurredAt: try when(), origin: origin)
    let captured = try LedgerTransactionTemplate(
      capturing: transfer, tags: .empty, id: try id("2", StableLedgerID.transactionTemplate),
      name: "ATM", origin: origin)
    #expect(captured.accountID == bank)
    #expect(captured.counterAccountID == cash)
    #expect(try captured.instantiate(occurredAt: try when(), origin: origin) == transfer)
  }

  @Test("editing a template changes future drafts only, and tombstoned ones cannot be used")
  func editsAffectFutureOnly() throws {
    let template = try LedgerTransactionTemplate(
      id: try id("1", StableLedgerID.transactionTemplate), name: "Milk", kind: .expense,
      categoryID: food, amount: try amount("56"), accountID: cash, origin: origin)
    let before = try template.instantiate(occurredAt: try when(), origin: origin)

    let edited = try template.edited(amount: try amount("60"), note: .some("Price went up"))
    #expect(edited.id == template.id)
    #expect(before.effects[0].amount == (try amount("56")))
    let after = try edited.instantiate(occurredAt: try when(), origin: origin)
    #expect(after.effects[0].amount == (try amount("60")))
    #expect(after.note == "Price went up")
    #expect(try edited.edited(note: .some(nil)).note == nil)

    let gone = try edited.tombstoned()
    #expect(gone.lifecycle == .tombstoned)
    #expect(throws: LedgerAnnotationError.tombstoned) {
      try gone.instantiate(occurredAt: try when(), origin: origin)
    }
    #expect(throws: LedgerAnnotationError.tombstoned) { try gone.renamed("Back") }
  }

  // MARK: Memos

  @Test("memos hold a dated body and tombstone instead of disappearing")
  func memosAreDatedAndTombstoned() throws {
    let date = try SourceLocalDate(year: 2026, month: 10, day: 31)
    let memo = try LedgerMemo(
      id: try id("1", StableLedgerID.memo), body: "Gas cylinder booked\nRef pending", date: date,
      origin: origin)
    #expect(memo.date == date)

    let moved = try memo.edited(date: try SourceLocalDate(year: 2026, month: 11, day: 1))
    #expect(moved.id == memo.id)
    #expect(moved.body == memo.body)

    let gone = try moved.tombstoned()
    #expect(gone.lifecycle == .tombstoned)
    #expect(throws: LedgerAnnotationError.tombstoned) { try gone.edited(body: "x") }

    for bad in ["", "   \n", String(repeating: "x", count: LedgerMemo.maximumBodyBytes + 1)] {
      #expect(throws: LedgerAnnotationError.invalidBody) {
        try LedgerMemo(id: memo.id, body: bad, date: date, origin: origin)
      }
    }
  }
}
