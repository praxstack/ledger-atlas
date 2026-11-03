import Foundation
import LedgerCore
import Testing

@testable import LedgerStore

// Synthetic data only: every name, amount and date here is made up.

/// MACV2-21 (#57) performance receipt: a 100,000-entry synthetic ledger on disk, timed through
/// the paths a person uses every day. Each operation has a ceiling; the receipt names the corpus,
/// operation, ceiling and result, and is written to `LEDGER_ATLAS_TEST_ARTIFACTS` when set (CI
/// uploads that folder).
///
/// Ceilings are for a debug build on a shared CI runner, set from main's macOS run after #139.
/// Open, report and save sit at about twice their time there. Read (a cache hit after open) and
/// search take well under a second, so their ceiling is 1 s. The rest stay loose and catch a
/// path that stops being paged or turns quadratic.
///
/// It takes a few minutes, so it runs only when `LEDGER_ATLAS_PERFORMANCE_RECEIPT` is set. CI
/// sets it in its own step on pushes to main and manual runs.
@Suite(
  "100,000-entry performance receipt", .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["LEDGER_ATLAS_PERFORMANCE_RECEIPT"] != nil))
struct LedgerPerformanceReceiptTests {
  static let transactionCount = 100_000

  @Test("a 100,000-entry ledger opens, browses, searches, saves and backs up within its ceilings")
  func receipt() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "performance-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let ledgerURL = directory.appendingPathComponent("ledger.sqlite")
    var receipt = Receipt(transactionCount: Self.transactionCount)

    // Write: one XLSX-import step adds the whole corpus, as a large first import would.
    let corpus = try Corpus()
    receipt.accountCount = corpus.content.accounts.count
    receipt.categoryCount = corpus.content.categories.count
    do {
      let created = try LedgerStoreLifecycle.create(at: ledgerURL)
      let application = LedgerApplication(store: created.store)
      let plan = try receipt.time("plan import of every entry", ceiling: 120) {
        try application.planXLSXImport(corpus.content)
      }
      #expect(plan.canApply)
      try receipt.time("write every entry in one step", ceiling: 300) {
        try application.applyXLSXImport(plan, createdAt: corpus.createdAt)
      }
    }
    receipt.fileBytes =
      (try FileManager.default.attributesOfItem(atPath: ledgerURL.path)[.size] as? NSNumber)?
      .intValue ?? 0

    // Open and read, as the app does when a ledger is chosen.
    let opened = try receipt.time("open the ledger", ceiling: 30) {
      try LedgerStoreLifecycle.open(at: ledgerURL)
    }
    let application = LedgerApplication(store: opened.store)
    let snapshot = try receipt.time("read every entry", ceiling: 1) {
      try opened.store.readSnapshot()
    }
    #expect(snapshot.transactions.count == Self.transactionCount)

    // Browse: the ledger screen's index, first page, a filtered page, jump-to and totals.
    let browser = receipt.time("build the browse index", ceiling: 10) {
      LedgerBrowser(transactions: snapshot.transactions)
    }
    let first = receipt.time("show the first page", ceiling: 1) {
      browser.page(mode: .daily, pageIndex: 0)
    }
    #expect(first.entries.count == LedgerBrowser.defaultPageSize)
    #expect(first.pageCount == Self.transactionCount / LedgerBrowser.defaultPageSize)
    let filtered = receipt.time("show a page filtered by note text", ceiling: 1) {
      browser.page(mode: .monthly, filter: .init(text: "lunch 7"), pageIndex: 0)
    }
    #expect(!filtered.entries.isEmpty)
    let target = browser.entries[Self.transactionCount * 7 / 8].id
    let position = receipt.time("find the page holding one entry", ceiling: 1) {
      browser.pageIndex(of: target, mode: .daily)
    }
    #expect(position != nil)
    _ = receipt.time("total income by day", ceiling: 3) {
      browser.totals(mode: .daily, filter: .init(kinds: [.income]))
    }

    // Search and report through the store.
    let found = try receipt.time("search by note", ceiling: 1) {
      try application.search(.init(noteContains: "lunch 77"))
    }
    #expect(!found.isEmpty)
    let report = try receipt.time("build the INR report", ceiling: 8) {
      try application.report(unitCode: "INR")
    }
    _ = report

    // Save one new expense, then back the ledger up.
    try receipt.time("save one new expense", ceiling: 35) {
      _ = try application.createTransaction(
        idempotencyKey: corpus.key("one-more"), draft: try corpus.expense(n: 0, note: "one more"),
        createdAt: corpus.createdAt)
    }
    let backupURL = directory.appendingPathComponent("backup.sqlite")
    try receipt.time("save a 1:1 backup", ceiling: 60) {
      _ = try opened.store.backupCanonicalDatabase(to: backupURL)
    }

    try receipt.publish()
    for operation in receipt.operations {
      #expect(
        operation.seconds <= operation.ceilingSeconds,
        "\(operation.name) took \(operation.seconds) s, ceiling \(operation.ceilingSeconds) s")
    }
  }
}

/// 100,000 synthetic entries over ten years: four in five are expenses, the rest income, across
/// two accounts and three categories, and one in seven carries a note.
private struct Corpus {
  let origin: LedgerOrigin
  let createdAt = UTCInstant(epochMilliseconds: 1_780_000_000_000)
  private(set) var content = LedgerXLSXExchange.Content()
  private let wallet: LedgerAccount
  private let bank: LedgerAccount
  private let food: LedgerCategory
  private let rent: LedgerCategory
  private let salary: LedgerCategory
  private let timeZone: SourceTimeZone

  init() throws {
    origin = try LedgerOrigin(id: String(repeating: "7", count: 64), label: "synthetic")
    timeZone = try SourceTimeZone(fixedOffsetSeconds: 19_800)
    wallet = try LedgerAccount(
      id: StableLedgerID.account(origin: origin, localKey: Self.key("wallet")), name: "Wallet",
      currencyUnit: "INR", origin: origin)
    bank = try LedgerAccount(
      id: StableLedgerID.account(origin: origin, localKey: Self.key("bank")), name: "Bank",
      currencyUnit: "INR", origin: origin)
    food = try LedgerCategory(
      id: StableLedgerID.category(origin: origin, localKey: Self.key("food")), name: "Food",
      kind: .expense, origin: origin)
    rent = try LedgerCategory(
      id: StableLedgerID.category(origin: origin, localKey: Self.key("rent")), name: "Rent",
      kind: .expense, origin: origin)
    salary = try LedgerCategory(
      id: StableLedgerID.category(origin: origin, localKey: Self.key("salary")), name: "Salary",
      kind: .income, origin: origin)
    var transactions: [LedgerXLSXExchange.Transaction] = []
    transactions.reserveCapacity(LedgerPerformanceReceiptTests.transactionCount)
    for n in 0..<LedgerPerformanceReceiptTests.transactionCount {
      let draft = n % 5 == 0 ? try income(n: n) : try expense(n: n, note: nil)
      transactions.append(
        .init(
          id: try StableLedgerID.transaction(origin: origin, localKey: Self.key("tx-\(n)")),
          draft: draft))
    }
    content = LedgerXLSXExchange.Content(
      accounts: [wallet, bank], categories: [food, rent, salary], transactions: transactions)
  }

  func key(_ seed: String) -> String { Self.key(seed) }

  /// A 64-character lowercase hex key from any seed.
  static func key(_ seed: String) -> String {
    let hex = seed.utf8.map { String(format: "%02x", $0) }.joined()
    return String((hex + String(repeating: "0", count: 64)).prefix(64))
  }

  private func when(_ n: Int) throws -> SourceTemporal {
    try SourceTemporal(
      resolving: SourceLocalDateTime(
        date: SourceLocalDate(year: 2016 + n % 10, month: 1 + n % 12, day: 1 + n % 28)),
      in: timeZone, precision: .day)
  }

  private func inr(_ n: Int) throws -> CurrencyAmount {
    try CurrencyAmount(unitCode: "INR", amount: ExactDecimal("\(1 + n % 997).\(10 + n % 90)"))
  }

  func expense(n: Int, note: String?) throws -> LedgerTransactionDraft {
    try LedgerTransactionDraft(
      effects: [
        LedgerTransactionEffect(
          accountID: n % 2 == 0 ? wallet.id : bank.id, direction: .decrease, amount: inr(n))
      ],
      categoryID: n % 3 == 0 ? rent.id : food.id, kind: .expense, occurredAt: when(n),
      note: note ?? (n % 7 == 0 ? "lunch \(n)" : nil), origin: origin)
  }

  private func income(n: Int) throws -> LedgerTransactionDraft {
    try LedgerTransactionDraft(
      effects: [LedgerTransactionEffect(accountID: bank.id, direction: .increase, amount: inr(n))],
      categoryID: salary.id, kind: .income, occurredAt: when(n), origin: origin)
  }
}

private struct Receipt: Encodable {
  struct Operation: Encodable {
    let name: String
    let seconds: Double
    let ceilingSeconds: Double
  }

  let transactionCount: Int
  var accountCount = 0
  var categoryCount = 0
  var fileBytes = 0
  #if DEBUG
    let build = "debug"
  #else
    let build = "release"
  #endif
  let platform = ProcessInfo.processInfo.operatingSystemVersionString
  private(set) var operations: [Operation] = []

  mutating func time<T>(_ name: String, ceiling: Double, _ body: () throws -> T) rethrows -> T {
    let clock = ContinuousClock()
    var result: T?
    let elapsed = try clock.measure { result = try body() }
    let seconds =
      Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    operations.append(
      .init(name: name, seconds: (seconds * 1000).rounded() / 1000, ceilingSeconds: ceiling))
    return result!
  }

  func publish() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(self)
    print("PERFORMANCE RECEIPT\n" + String(decoding: data, as: UTF8.self))
    if let folder = ProcessInfo.processInfo.environment["LEDGER_ATLAS_TEST_ARTIFACTS"] {
      let url = URL(fileURLWithPath: folder, isDirectory: true)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try data.write(to: url.appendingPathComponent("performance-receipt-100k.json"))
    }
  }
}
