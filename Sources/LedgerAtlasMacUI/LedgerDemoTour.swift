import AppKit
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

  /// Screens shown in the tour, in order. Onboarding and import review come last because they
  /// describe the empty and import states rather than the open ledger.
  package static let destinations: [AppDestination] = [
    .ledger, .accounts, .categories, .tags, .transfers, .recurrence, .installments, .budgets,
    .insights, .search, .receipts, .backupRestore, .localAccess, .settings, .onboarding,
    .importReview,
  ]

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

  /// Writes a small, made-up household ledger: four accounts, a category tree, about three
  /// months of income and spending, transfers (one in another currency), a monthly rent rule
  /// and a groceries budget.
  package static func makeDemoLedger(at url: URL) throws {
    let store = try LedgerStoreLifecycle.create(at: url).store
    let app = LedgerApplication(store: store)
    let origin = try LedgerOrigin(id: key("demo-origin"), label: "local")
    func account(_ name: String, _ unit: String) throws -> LedgerAccount {
      try LedgerAccount(
        id: StableLedgerID.account(origin: origin, localKey: key("account-\(name)")),
        name: name, currencyUnit: unit, origin: origin)
    }
    func category(_ name: String, _ kind: LedgerCategoryKind) throws -> LedgerCategory {
      try LedgerCategory(
        id: StableLedgerID.category(origin: origin, localKey: key("category-\(name)")),
        name: name, kind: kind, origin: origin)
    }
    let cash = try account("Cash", "INR")
    let bank = try account("Everyday Bank", "INR")
    let card = try account("Rewards Card", "INR")
    let travel = try account("Travel Wallet", "USD")
    for item in [cash, bank, card, travel] { try app.createAccount(item) }
    let salary = try category("Salary", .income)
    let food = try category("Food", .expense)
    let groceries = try category("Groceries", .expense)
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
      CurrencyAmount(unitCode: "INR", amount: try ExactDecimal(value))
    }
    var sequence = 0
    func add(
      _ kind: LedgerTransactionKind, _ account: LedgerAccount, _ category: LedgerCategory?,
      _ amount: String, _ month: Int, _ day: Int, note: String? = nil
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
        createdAt: UTCInstant(epochMilliseconds: 1_790_000_000_000 + Int64(sequence)))
    }
    let spending: [(LedgerCategory, LedgerAccount, [String])] = [
      (food, card, ["420.00", "185.50", "640.00", "312.25", "275.00"]),
      (groceries, bank, ["1840.00", "2215.75", "1390.40"]),
      (transport, cash, ["120.00", "95.00", "260.00", "80.00"]),
      (fun, card, ["899.00", "450.00"]),
    ]
    for month in 8...10 {
      try add(.income, bank, salary, "85000.00", month, 1, note: "Monthly salary")
      try add(.expense, bank, rent, "24000.00", month, 3, note: "Flat rent")
      for (index, (category, account, amounts)) in spending.enumerated() {
        for (offset, amount) in amounts.enumerated() {
          try add(.expense, account, category, amount, month, 4 + index * 6 + offset)
        }
      }
      _ = try app.createTransfer(
        idempotencyKey: key("demo-transfer-\(month)"), sourceAccountID: bank.id,
        destinationAccountID: cash.id, sourceAmount: try inr("3000.00"),
        destinationAmount: try inr("3000.00"), conversion: nil, fee: nil, feeAccountID: nil,
        occurredAt: try when(month, 15), origin: origin,
        createdAt: UTCInstant(epochMilliseconds: 1_790_100_000_000 + Int64(month)))
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
