import Foundation
import LedgerCore
import Testing

@Suite("Ledger browser")
struct LedgerBrowserTests {
  private static let origin = try! LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  private static let cash = String(repeating: "a", count: 64)
  private static let bank = String(repeating: "b", count: 64)
  private static let food = String(repeating: "c", count: 64)
  private static let salary = String(repeating: "d", count: 64)

  /// Synthetic entry `n`: a fixed day/time, kind and amount, with no real data.
  private static func transaction(
    _ n: Int, year: Int = 2026, month: Int = 1, day: Int = 1, hour: Int = 9,
    kind: LedgerTransactionKind = .expense, amount: String = "1.00", unit: String = "USD",
    note: String? = nil, account: String = cash, category: String? = food, revision: Int = 1,
    lifecycle: LedgerLifecycleState = .active
  ) throws -> LedgerTransactionSnapshot {
    let transactionID = try StableLedgerID.transaction(
      origin: origin, localKey: String(format: "%064x", n))
    let money = try CurrencyAmount(unitCode: unit, amount: ExactDecimal(amount))
    let effects: [LedgerTransactionEffect]
    switch kind {
    case .income:
      effects = [try .init(accountID: account, direction: .increase, amount: money)]
    case .expense, .adjustment:
      effects = [try .init(accountID: account, direction: .decrease, amount: money)]
    case .transfer:
      effects = [
        try .init(accountID: account, direction: .decrease, amount: money),
        try .init(accountID: account == cash ? bank : cash, direction: .increase, amount: money),
      ]
    }
    let when = try SourceTemporal(
      resolving: SourceLocalDateTime(
        date: SourceLocalDate(year: year, month: month, day: day), hour: hour),
      in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .minute)
    let draft = try LedgerTransactionDraft(
      effects: effects, categoryID: kind == .transfer ? nil : category, kind: kind,
      occurredAt: when, note: note, origin: origin)
    let revisionRecord = try LedgerTransactionRevision(
      id: StableLedgerID.revision(transactionID: transactionID, revision: revision),
      transactionID: transactionID, revision: revision,
      predecessorID: revision > 1
        ? try StableLedgerID.revision(transactionID: transactionID, revision: revision - 1) : nil,
      draft: draft, lifecycle: lifecycle, createdAt: UTCInstant(epochMilliseconds: 0))
    return try LedgerTransactionSnapshot(id: transactionID, currentRevision: revisionRecord)
  }

  private static func sample() throws -> [LedgerTransactionSnapshot] {
    [
      try transaction(1, day: 1, amount: "4.50", note: "Coffee beans"),
      try transaction(2, day: 1, hour: 18, kind: .income, amount: "100", category: salary),
      try transaction(3, day: 2, amount: "2.25", account: bank),
      try transaction(4, month: 2, day: 3, kind: .transfer, amount: "10"),
      try transaction(5, month: 2, day: 3, amount: "7", revision: 2),
      try transaction(6, month: 2, day: 4, amount: "3", note: "Taxi", lifecycle: .tombstoned),
      try transaction(7, month: 2, day: 4, kind: .expense, amount: "5", unit: "EUR"),
    ]
  }

  @Test("entries are newest first with a stable order and indicators")
  func ordersAndMarksEntries() throws {
    let browser = LedgerBrowser(transactions: try Self.sample())
    let dates = browser.entries.map { $0.occurredAt }
    #expect(dates == dates.sorted(by: >))
    let edited = try #require(browser.entries.first { $0.revision == 2 })
    #expect(edited.indicators == [.edited])
    let closed = try #require(browser.entries.first { $0.lifecycle == .tombstoned })
    #expect(closed.indicators == [.note, .closed])
    #expect(browser.entries.first { $0.kind == .transfer }?.indicators == [.transfer])
    // Same input in another order gives the same order.
    let shuffled = LedgerBrowser(transactions: try Self.sample().reversed())
    #expect(shuffled.entries.map(\.id) == browser.entries.map(\.id))
  }

  @Test("a cross-currency transfer shows what arrived, the rate and the rounding")
  func showsConversionDetail() throws {
    let usd = try CurrencyAmount(unitCode: "USD", amount: ExactDecimal("100"))
    let inr = try CurrencyAmount(unitCode: "INR", amount: ExactDecimal("8325.50"))
    let conversion = try LedgerConversion(
      sourceAmount: usd, convertedAmount: inr, rate: ExactDecimal("0.0120112906"),
      rateScale: 10, rounding: .halfEven)
    let transactionID = try StableLedgerID.transaction(
      origin: Self.origin, localKey: String(format: "%064x", 99))
    let when = try SourceTemporal(
      resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 3, day: 1), hour: 9),
      in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .minute)
    let draft = try LedgerTransactionDraft(
      effects: [
        try .init(accountID: Self.cash, direction: .decrease, amount: usd),
        try .init(accountID: Self.bank, direction: .increase, amount: inr),
      ], categoryID: nil, kind: .transfer, occurredAt: when,
      roundingPolicy: conversion.rounding, sourceLiterals: try conversion.literals,
      origin: Self.origin)
    let revision = try LedgerTransactionRevision(
      id: StableLedgerID.revision(transactionID: transactionID, revision: 1),
      transactionID: transactionID, revision: 1, predecessorID: nil, draft: draft,
      createdAt: UTCInstant(epochMilliseconds: 0))
    let fx = try LedgerTransactionSnapshot(id: transactionID, currentRevision: revision)

    let browser = LedgerBrowser(transactions: try Self.sample() + [fx])

    let entry = try #require(browser.entry(id: transactionID))
    #expect(entry.indicators == [.transfer, .conversion])
    #expect(
      entry.conversion
        == "received 8325.50 INR, rate 0.0120112906 USD per INR, rounding halfEven")
    // Same-currency transfers and everything else carry no conversion line.
    #expect(browser.entries.filter { $0.id != transactionID }.allSatisfy { $0.conversion == nil })
  }

  @Test("five modes group by day, month, everything, or notes only")
  func groupsByMode() throws {
    let browser = LedgerBrowser(transactions: try Self.sample())
    #expect(
      browser.page(mode: .daily, pageIndex: 0).sections.map(\.id)
        == ["2026-02-04", "2026-02-03", "2026-01-02", "2026-01-01"])
    #expect(
      browser.page(mode: .calendar, pageIndex: 0).sections.map(\.id)
        == ["2026-02-04", "2026-02-03", "2026-01-02", "2026-01-01"])
    #expect(browser.page(mode: .monthly, pageIndex: 0).sections.map(\.id) == ["2026-02", "2026-01"])
    #expect(browser.page(mode: .total, pageIndex: 0).sections.map(\.id) == ["total"])
    let notes = browser.page(mode: .note, pageIndex: 0)
    #expect(notes.matchCount == 2)
    #expect(notes.entries.allSatisfy { $0.note != nil })
  }

  @Test("totals count active income and expense per currency, across pages")
  func totalsAreExactAndPerCurrency() throws {
    let browser = LedgerBrowser(transactions: try Self.sample())
    let page = browser.page(mode: .monthly, pageIndex: 0, pageSize: 1)
    #expect(page.pageCount == 7)
    #expect(page.sections.count == 1)
    let january = try LedgerBrowser(transactions: Self.sample())
      .page(mode: .monthly, pageIndex: 3, pageSize: 2)
    // Page 3 holds January entries; its section total covers all of January, not just the page.
    let section = try #require(january.sections.first { $0.id == "2026-01" })
    #expect(section.totals.map(\.unitCode) == ["USD"])
    #expect(section.totals.first?.income?.rawLiteral == "100")
    #expect(section.totals.first?.expense?.rawLiteral == "6.75")
    // Overall: closed entries and transfers do not count; EUR stays separate.
    let overall = browser.totals(mode: .total)
    #expect(overall.map(\.unitCode) == ["EUR", "USD"])
    #expect(overall.first?.expense?.rawLiteral == "5")
    #expect(overall.last?.expense?.rawLiteral == "13.75")
  }

  @Test("filters narrow by text, account, category, kind, closed and day")
  func filtersNarrow() throws {
    let browser = LedgerBrowser(
      transactions: try Self.sample(), accountNames: [Self.bank: "Bank"],
      categoryNames: [Self.salary: "Salary"])
    func count(_ filter: LedgerBrowseFilter) -> Int {
      browser.page(mode: .daily, filter: filter, pageIndex: 0).matchCount
    }
    #expect(!LedgerBrowseFilter().isActive)
    #expect(count(.init(text: "coffee")) == 1)
    #expect(count(.init(text: "  COFFEE beans ")) == 1)
    #expect(count(.init(text: "salary")) == 1)
    #expect(count(.init(text: "bank")) == 2)  // the bank expense and the transfer into bank
    #expect(count(.init(text: "eur")) == 1)
    #expect(count(.init(accountID: Self.bank)) == 2)
    #expect(count(.init(categoryID: Self.salary)) == 1)
    #expect(count(.init(kinds: [.income, .transfer])) == 2)
    #expect(count(.init(includesClosed: false)) == 6)
    #expect(count(.init(day: try SourceLocalDate(year: 2026, month: 2, day: 4))) == 2)
    let none = browser.page(mode: .daily, filter: .init(text: "nothing-like-this"), pageIndex: 0)
    #expect(none.matchCount == 0)
    #expect(none.sections.isEmpty)
    #expect(none.pageCount == 1)
  }

  @Test("an edited entry is found again on its page")
  func editReturnsToTheSamePosition() throws {
    var transactions = try (0..<250).map {
      try Self.transaction($0, day: 1 + $0 % 28, hour: $0 % 24)
    }
    let browser = LedgerBrowser(transactions: transactions)
    let target = browser.entries[173].id
    #expect(browser.pageIndex(of: target, mode: .daily, pageSize: 100) == 1)
    // The edit bumps the revision and amount; position stays the same.
    let index = try #require(transactions.firstIndex { $0.id == target })
    transactions[index] = try Self.transaction(
      index, day: 1 + index % 28, hour: index % 24, amount: "9.99", revision: 2)
    let after = LedgerBrowser(transactions: transactions)
    #expect(after.pageIndex(of: target, mode: .daily, pageSize: 100) == 1)
    #expect(after.entry(id: target)?.indicators.contains(.edited) == true)
    #expect(after.pageIndex(of: target, mode: .note) == nil)
    #expect(after.pageIndex(of: String(repeating: "0", count: 64), mode: .daily) == nil)
    // Out-of-range pages clamp instead of showing nothing.
    #expect(after.page(mode: .daily, pageIndex: 99).pageIndex == 2)
    #expect(after.page(mode: .daily, pageIndex: -4).pageIndex == 0)
  }

  @Test("calendar summarizes each day of a month")
  func calendarDays() throws {
    let browser = LedgerBrowser(transactions: try Self.sample())
    let days = browser.calendar(year: 2026, month: 2)
    #expect(days.map(\.date.day) == [3, 4])
    #expect(days.map(\.count) == [2, 2])
    #expect(days.first?.totals.first?.expense?.rawLiteral == "7")
    #expect(browser.calendar(year: 2026, month: 3).isEmpty)
  }

  @Test("a 100,000-entry ledger stays paged and fast")
  func largeLedgerStaysPaged() throws {
    let units = ["USD", "EUR", "INR"]
    let transactions = try (0..<100_000).map { n in
      try Self.transaction(
        n, year: 2016 + n % 10, month: 1 + n % 12, day: 1 + n % 28, hour: n % 24,
        kind: n % 5 == 0 ? .income : .expense, amount: "\(1 + n % 997).\(n % 100)",
        unit: units[n % 3], note: n % 7 == 0 ? "note \(n)" : nil,
        account: n % 2 == 0 ? Self.cash : Self.bank)
    }
    let clock = ContinuousClock()
    var browser: LedgerBrowser?
    let build = clock.measure { browser = LedgerBrowser(transactions: transactions) }
    let ledger = try #require(browser)
    var page: LedgerBrowsePage?
    let firstPage = clock.measure { page = ledger.page(mode: .daily, pageIndex: 0) }
    let filtered = clock.measure {
      _ = ledger.page(mode: .monthly, filter: .init(text: "note 7"), pageIndex: 3)
    }
    let totals = clock.measure { _ = ledger.totals(mode: .daily, filter: .init(kinds: [.income])) }
    let target = ledger.entries[87_654].id
    var position: Int?
    let locate = clock.measure { position = ledger.pageIndex(of: target, mode: .daily) }

    #expect(page?.entries.count == LedgerBrowser.defaultPageSize)
    #expect(page?.pageCount == 1_000)
    #expect(position == 876)
    // Generous ceilings for a debug build on a shared CI runner; a regression to quadratic work
    // would blow far past them.
    #expect(build < .seconds(5), "build took \(build)")
    #expect(firstPage < .seconds(1), "first page took \(firstPage)")
    #expect(filtered < .seconds(1), "filtered page took \(filtered)")
    #expect(locate < .seconds(1), "locating an entry took \(locate)")
    #expect(totals < .seconds(2), "totals took \(totals)")
  }

  @Test func tagFilterAndSearchUseTheCurrentRevisionsTags() throws {
    let transactions = try Self.sample()
    let trip = String(repeating: "e", count: 64)
    let shared = String(repeating: "f", count: 64)
    let first = transactions[0].currentRevision.id
    let third = transactions[2].currentRevision.id
    let browser = LedgerBrowser(
      transactions: transactions,
      revisionTags: [first: try LedgerTagLinks([trip, shared]), third: try LedgerTagLinks([trip])],
      tagNames: [trip: "Goa trip", shared: "Shared"])

    #expect(browser.entry(id: transactions[0].id)?.tagIDs == [trip, shared].sorted())
    #expect(browser.entry(id: transactions[1].id)?.tagIDs == [])

    let byTag = LedgerBrowseFilter(tagID: trip)
    #expect(byTag.isActive)
    #expect(
      Set(browser.page(mode: .total, filter: byTag, pageIndex: 0).entries.map(\.id))
        == [transactions[0].id, transactions[2].id])
    #expect(
      browser.page(mode: .total, filter: .init(tagID: shared), pageIndex: 0).entries.map(\.id)
        == [transactions[0].id])

    // Tag names are searchable like category and account names.
    #expect(
      browser.page(mode: .total, filter: .init(text: "goa"), pageIndex: 0).matchCount == 2)
  }
}
