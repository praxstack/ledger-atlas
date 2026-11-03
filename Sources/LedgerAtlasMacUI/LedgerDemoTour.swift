import AppKit
internal import CSQLite
import CryptoKit
import Foundation
import LedgerCore
import LedgerStore

/// A guided capture of the real app for release notes and CI, run only when the
/// `LEDGER_ATLAS_DEMO_TOUR` environment variable is set. It writes a synthetic demo ledger to app
/// storage, opens it through the normal lifecycle, shows each screen and saves a PNG of the
/// window. No personal data is involved: every name and amount below is made up.
package enum LedgerDemoTour {
  package static var isRequested: Bool {
    !(ProcessInfo.processInfo.environment["LEDGER_ATLAS_DEMO_TOUR"] ?? "").isEmpty
  }

  /// With the tour: the file name of a made-up backup in the app's temporary folder to import
  /// instead of touring (scripts/ci/make-synthetic-backup.py). A bare name, never a path.
  package static var fullSizeBackupName: String? {
    guard let name = ProcessInfo.processInfo.environment["LEDGER_ATLAS_DEMO_IMPORT"],
      !name.isEmpty, !name.contains("/"), name != "..", name != "."
    else { return nil }
    return name
  }

  /// Screens shown in the tour, in order. Onboarding and import review come last because they
  /// describe the empty and import states rather than the open ledger.
  package static let destinations: [AppDestination] = [
    .overview, .ledger, .accounts, .categories, .tags, .transfers, .recurrence, .installments, .budgets,
    .insights, .search, .receipts, .backupRestore, .localAccess, .settings, .onboarding,
    .importReview,
  ]

  /// The tour only runs where no ledger exists yet (a fresh CI runner), so it can never touch
  /// a person's ledgers. Returns the demo ledger's URL in app storage.
  package static func demoLedgerURL(in ledgers: URL) throws -> URL? {
    let existing = try FileManager.default.contentsOfDirectory(atPath: ledgers.path)
      .filter { !$0.hasPrefix(".") }
    guard existing.isEmpty else { return nil }
    return ledgers.appendingPathComponent("Demo Household.sqlite")
  }

  /// Removes the demo ledger and everything the store kept beside it. Matching by prefix is safe
  /// only here: the tour runs in an otherwise empty ledgers folder (`demoLedgerURL`).
  package static func removeDemoLedger(at url: URL) {
    let directory = url.deletingLastPathComponent()
    let stem = url.lastPathComponent
    for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    where name.hasPrefix(stem) {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
  }

  /// A made-up Money Manager v19 backup: one account, one category, one expense.
  package static func writeMoneyManagerBackup(to url: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
      sqlite3_close(database)
      throw CocoaError(.fileWriteUnknown)
    }
    defer { sqlite3_close(database) }
    let sql = """
      PRAGMA user_version=19;
      CREATE TABLE ASSETS (uid TEXT); CREATE TABLE ZCATEGORY (uid TEXT);
      CREATE TABLE CURRENCY (uid TEXT, ISO TEXT);
      CREATE TABLE INOUTCOME (uid TEXT, assetUid TEXT, currencyUid TEXT, DO_TYPE TEXT, ctgUid TEXT, ZMONEY TEXT, WDATE TEXT, ZDATE TEXT, NOTE TEXT);
      INSERT INTO ASSETS VALUES ('asset'); INSERT INTO ZCATEGORY VALUES ('category');
      INSERT INTO CURRENCY VALUES ('currency', 'USD');
      INSERT INTO INOUTCOME VALUES ('transaction', 'asset', 'currency', '1', 'category', '12.30', '2025-02-03', '1738547200000', 'demo');
      """
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
      throw CocoaError(.fileWriteUnknown)
    }
  }

  package static func outputDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "LedgerAtlasDemoTour", isDirectory: true)
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Saves what the window shows, without needing screen-recording permission.
  @MainActor
  package static func capture(to url: URL) -> Bool {
    guard
      let window = NSApplication.shared.windows.first(where: {
        $0.isVisible && $0.contentView != nil && $0.frame.width > 400
      }),
      let view = window.contentView?.superview ?? window.contentView,
      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { return false }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: url)) != nil
  }

  private static func key(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// Writes a small, made-up household ledger: seven accounts in three groups (one hidden, one
  /// an investment), a category tree with a subcategory, about three months of income and
  /// spending, transfers (one in another currency), a monthly rent rule and a groceries budget.
  package static func makeDemoLedger(at url: URL) throws {
    let store = try LedgerStoreLifecycle.create(at: url).store
    let app = LedgerApplication(store: store)
    let origin = try LedgerOrigin(id: key("demo-origin"), label: "local")
    // Account groups, so the Accounts screen shows grouped cards with subtotals.
    let groups = try ["Cash & Bank", "Cards", "Savings & Investments"].enumerated().map {
      try LedgerAccountGroup(id: key("group-\($0.element)"), name: $0.element, displayOrder: $0.offset)
    }
    for group in groups { try app.createAccountGroup(group) }
    func account(
      _ name: String, _ unit: String, group: Int?, order: Int, hidden: Bool = false,
      variant: LedgerAccountVariant = .standard
    ) throws -> LedgerAccount {
      try LedgerAccount(
        id: StableLedgerID.account(origin: origin, localKey: key("account-\(name)")),
        name: name, currencyUnit: unit, origin: origin, groupID: group.map { groups[$0].id },
        displayOrder: order, hidden: hidden, variant: variant)
    }
    func category(
      _ name: String, _ kind: LedgerCategoryKind, parent: LedgerCategory? = nil
    ) throws -> LedgerCategory {
      try LedgerCategory(
        id: StableLedgerID.category(origin: origin, localKey: key("category-\(name)")),
        name: name, kind: kind, origin: origin, parentID: parent?.id)
    }
    let cash = try account("Cash", "INR", group: 0, order: 0)
    let bank = try account("Everyday Bank", "INR", group: 0, order: 1)
    let card = try account("Rewards Card", "INR", group: 1, order: 0)
    let travel = try account("Travel Wallet", "USD", group: nil, order: 0)
    let savings = try account("Emergency Savings", "INR", group: 2, order: 0)
    let fund = try account("Index Fund", "INR", group: 2, order: 1, variant: .investment)
    let oldWallet = try account("Old Wallet", "INR", group: 0, order: 2, hidden: true)
    for item in [cash, bank, card, travel, savings, fund, oldWallet] {
      try app.createAccount(item)
    }
    let salary = try category("Salary", .income)
    let food = try category("Food", .expense)
    let groceries = try category("Groceries", .expense, parent: food)
    let rent = try category("Rent", .expense)
    let transport = try category("Transport", .expense)
    let fun = try category("Entertainment", .expense)
    for item in [salary, food, groceries, rent, transport, fun] { try app.createCategory(item) }

    let zone = try SourceTimeZone(ianaIdentifier: "Asia/Kolkata")
    func when(_ month: Int, _ day: Int, _ hour: Int = 12) throws -> SourceTemporal {
      try SourceTemporal(
        resolving: SourceLocalDateTime(
          date: SourceLocalDate(year: 2026, month: month, day: day), hour: hour, minute: 0,
          second: 0, millisecond: 0),
        in: zone, precision: .minute, ambiguityPolicy: .reject)
    }
    func inr(_ value: String) throws -> CurrencyAmount {
      try CurrencyAmount(unitCode: "INR", amount: try ExactDecimal(value))
    }
    var sequence = 0
    let tags = try ["Household", "Weekend", "Work"].map {
      try LedgerTag(id: key("tag-\($0)"), name: $0, origin: origin)
    }
    for tag in tags { try app.createTag(tag) }
    func add(
      _ kind: LedgerTransactionKind, _ account: LedgerAccount, _ category: LedgerCategory?,
      _ amount: String, _ month: Int, _ day: Int, note: String? = nil, tag: LedgerTag? = nil
    ) throws {
      sequence += 1
      let draft = try LedgerTransactionDraft(
        effects: [
          try LedgerTransactionEffect(
            accountID: account.id, direction: kind == .income ? .increase : .decrease,
            amount: try inr(amount))
        ], categoryID: category?.id, kind: kind, occurredAt: try when(month, day),
        note: note, origin: origin)
      _ = try app.createTransaction(
        idempotencyKey: key("demo-\(sequence)"), draft: draft,
        createdAt: UTCInstant(epochMilliseconds: 1_790_000_000_000 + Int64(sequence)),
        tags: try LedgerTagLinks(tag.map { [$0.id] } ?? []))
    }
    let spending: [(LedgerCategory, LedgerAccount, [String])] = [
      (food, card, ["420.00", "185.50", "640.00", "312.25", "275.00"]),
      (groceries, bank, ["1840.00", "2215.75", "1390.40"]),
      (transport, cash, ["120.00", "95.00", "260.00", "80.00"]),
      (fun, card, ["899.00", "450.00"]),
    ]
    try add(.income, savings, nil, "150000.00", 8, 1, note: "Opening balance")
    try add(.income, fund, nil, "220000.00", 8, 1, note: "Opening balance")
    for month in 8...10 {
      try add(.income, bank, salary, "85000.00", month, 1, note: "Monthly salary")
      try add(.expense, bank, rent, "24000.00", month, 3, note: "Flat rent")
      for (index, (category, account, amounts)) in spending.enumerated() {
        for (offset, amount) in amounts.enumerated() {
          try add(
            .expense, account, category, amount, month, 4 + index * 6 + offset,
            tag: [tags[0], tags[1], nil][(offset + index) % 3])
        }
      }
      _ = try app.createTransfer(
        idempotencyKey: key("demo-transfer-\(month)"), sourceAccountID: bank.id,
        destinationAccountID: cash.id, sourceAmount: try inr("3000.00"),
        destinationAmount: try inr("3000.00"), conversion: nil, fee: nil, feeAccountID: nil,
        occurredAt: try when(month, 15), origin: origin,
        createdAt: UTCInstant(epochMilliseconds: 1_790_100_000_000 + Int64(month)))
    }
    // A currency transfer: 41,625 INR left the bank and 500 USD arrived in the travel wallet.
    let sent = try inr("41625.00")
    let received = try CurrencyAmount(unitCode: "USD", amount: try ExactDecimal("500.00"))
    _ = try app.createTransfer(
      idempotencyKey: key("demo-fx"), sourceAccountID: bank.id, destinationAccountID: travel.id,
      sourceAmount: sent, destinationAmount: received,
      conversion: try LedgerConversion(
        sourceAmount: sent, convertedAmount: received,
        rate: try LedgerConversion.impliedRate(sourceAmount: sent, convertedAmount: received, scale: 4),
        rateScale: 4, rounding: .halfEven),
      fee: try inr("150.00"), feeAccountID: bank.id, occurredAt: try when(9, 20),
      origin: origin, createdAt: UTCInstant(epochMilliseconds: 1_790_200_000_000))
    for (index, body) in ["Pay electricity before the 10th", "Trip budget: 500 USD"].enumerated() {
      try app.saveMemo(
        LedgerMemo(
          id: key("memo-\(index)"), body: body,
          date: try SourceLocalDate(year: 2026, month: 9 + index, day: 5), origin: origin))
    }
    let rule = try LedgerRecurrenceRule(
      id: StableLedgerID.recurrenceRule(origin: origin, localKey: key("rule-rent")),
      origin: origin, accountID: bank.id, categoryID: rent.id, kind: .expense,
      amount: try inr("24000.00"), frequency: .monthly, interval: 1, dayOfMonth: 3,
      timeZone: zone, start: try SourceLocalDate(year: 2026, month: 11, day: 3))
    try app.createRecurrence(rule)
    try app.createBudget(
      LedgerBudget(
        id: StableLedgerID.budget(origin: origin, localKey: key("budget-groceries")),
        origin: origin, name: "Groceries", categoryID: groceries.id,
        amount: try inr("6000.00"), period: .monthly, rollover: true,
        start: try SourceLocalDate(year: 2026, month: 8, day: 1)))
  }
}
