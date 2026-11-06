import Foundation
import LedgerAdapterSemantics
import LedgerCore

/// What Money Manager itself would show for each account, worked out from the backup's own
/// rows by Money Manager's own rule, before anything is written to the ledger.
///
/// A v19 backup stores no account balance anywhere (checked on the real backup of 2026-11-01:
/// `ASSETS` has no balance column and `INOUTCOME.AMOUNT_ACCOUNT` is a copy of `ZMONEY` on every
/// row). The app's figure is the signed sum of the account's rows: income (0), transfer in (4)
/// and a quiet balance increase (7) add; expense (1), transfer out (3) and a quiet balance
/// decrease (8) subtract; deleted rows do not count. That sum is taken here from the staged
/// source records in Money Manager's vocabulary, never from the ledger Ledger Atlas writes, so
/// the receipt that compares the two is an independent check of the import mapping.
public struct MoneyManagerV19SourceBalances: Codable, Equatable, Sendable {
  public struct Account: Codable, Equatable, Sendable {
    public enum Figure: Codable, Equatable, Sendable {
      /// The signed balance as an exact decimal literal.
      case amount(String)
      /// Money Manager's figure cannot be worked out from the backup; the reason is shown.
      case unavailable(reason: String)
    }

    public let sourceAccountUID: String
    /// The ledger account this source account becomes on import.
    public let ledgerAccountID: String
    public let name: String
    public let currencyUnit: String?
    public let figure: Figure
    /// `ASSETS.ZDATA`: 0 shown, 1 deleted, 3 unshown (hidden in the app).
    public let deletedInSource: Bool
    public let hiddenInSource: Bool
    /// `ASSETS.ZDATA2` 1: left out of the app's totals.
    public let excludedFromTotalsInSource: Bool
    /// Rows that moved this account in Money Manager.
    public let countedRowCount: Int
    /// Rows Money Manager counts that the import keeps as preserved source instead of mapping
    /// (an orphan transfer leg, an unknown type). They explain a difference.
    public let notImportedRowCount: Int
    /// Display order from the source, then name.
    public let displayOrder: Int

    public init(
      sourceAccountUID: String, ledgerAccountID: String, name: String, currencyUnit: String?,
      figure: Figure, deletedInSource: Bool, hiddenInSource: Bool,
      excludedFromTotalsInSource: Bool, countedRowCount: Int, notImportedRowCount: Int,
      displayOrder: Int
    ) {
      self.sourceAccountUID = sourceAccountUID
      self.ledgerAccountID = ledgerAccountID
      self.name = name
      self.currencyUnit = currencyUnit
      self.figure = figure
      self.deletedInSource = deletedInSource
      self.hiddenInSource = hiddenInSource
      self.excludedFromTotalsInSource = excludedFromTotalsInSource
      self.countedRowCount = countedRowCount
      self.notImportedRowCount = notImportedRowCount
      self.displayOrder = displayOrder
    }
  }

  public let accounts: [Account]
  /// The newest civil day (`WDATE`) among the rows that count, as `YYYY-MM-DD`.
  public let throughDay: String?
  public let countedRowCount: Int

  public init(accounts: [Account], throughDay: String?, countedRowCount: Int) {
    self.accounts = accounts
    self.throughDay = throughDay
    self.countedRowCount = countedRowCount
  }
}

enum MoneyManagerV19BalanceOracle {
  static let shownStateAliases = ["ZDATA", "ZZDATA", "IS_SHOW"]
  static let excludedFromTotalsAliases = ["ZDATA2", "ZZDATA2"]
  static let displayOrderAliases = ["ORDERSEQ", "ORDER_SEQ", "ZORDERSEQ"]
  static let deletedAccountState = "1"
  static let hiddenAccountState = "3"
  static let excludedFromTotalsFlag = "1"

  /// The sign each `DO_TYPE` gives an account's balance in Money Manager. Nil for a type the
  /// app has never been observed to use; an account with such a row gets no figure.
  static func sign(forType type: String) -> Int? {
    switch type {
    case "0", MoneyManagerV19Vocabulary.transferCreditType,
      MoneyManagerV19Vocabulary.balanceIncreaseType:
      1
    case "1", MoneyManagerV19Vocabulary.transferDebitType,
      MoneyManagerV19Vocabulary.balanceDecreaseType:
      -1
    default: nil
    }
  }

  /// `mappedRecordIDs` are the transaction records the import maps to ledger events; every
  /// other counted row is reported as not imported, so a difference explains itself.
  static func balances(
    _ input: MoneyManagerV19AdapterInput, mappedRecordIDs: Set<String>
  ) throws -> MoneyManagerV19SourceBalances {
    var isoByCurrencyUID: [String: String] = [:]
    for currency in input.currencies {
      guard let uid = literal(currency, MoneyManagerV19Vocabulary.uidAliases),
        let iso = literal(currency, MoneyManagerV19Vocabulary.isoAliases)
      else { continue }
      isoByCurrencyUID[uid] = iso
    }

    struct Running {
      var sum: ExactDecimal
      var unavailable: String?
      var counted = 0
      var notImported = 0
      var rowCurrencies: Set<String> = []
    }
    let zero = try ExactDecimal("0")
    var running: [String: Running] = [:]
    var throughDay: String?
    var countedRows = 0
    for row in input.transactions {
      guard MoneyManagerV19Vocabulary.isTransactionTable(row.tableName) else { continue }
      if let deleted = literal(row, MoneyManagerV19Vocabulary.deletedAliases), !deleted.isEmpty,
        deleted != "0"
      {
        continue
      }
      guard let accountUID = literal(row, MoneyManagerV19Vocabulary.assetAliases),
        !accountUID.isEmpty
      else { continue }
      var state = running[accountUID] ?? Running(sum: zero)
      defer { running[accountUID] = state }
      state.counted += 1
      countedRows += 1
      if !mappedRecordIDs.contains(row.sourceRecordID) { state.notImported += 1 }
      if let day = literal(row, MoneyManagerV19Vocabulary.wdateAliases), isCivilDay(day),
        throughDay.map({ day > $0 }) ?? true
      {
        throughDay = day
      }
      if let currencyUID = literal(row, MoneyManagerV19Vocabulary.currencyUIDAliases) {
        state.rowCurrencies.insert(currencyUID)
      }
      guard state.unavailable == nil else { continue }
      guard let type = literal(row, MoneyManagerV19Vocabulary.doTypeAliases),
        let sign = sign(forType: type)
      else {
        state.unavailable = "an entry has a type Money Manager has not been seen to use"
        continue
      }
      guard let amountLiteral = literal(row, MoneyManagerV19Vocabulary.amountAliases),
        let amount = try? ExactDecimal(amountLiteral)
      else {
        state.unavailable = "an entry's amount is not an exact decimal"
        continue
      }
      state.sum = sign > 0 ? try state.sum.adding(amount) : try state.sum.subtracting(amount)
    }

    var accounts: [MoneyManagerV19SourceBalances.Account] = []
    for (index, asset) in input.assets.enumerated() {
      guard let uid = literal(asset, MoneyManagerV19Vocabulary.uidAliases), !uid.isEmpty else {
        continue
      }
      let ledgerAccountID = try StableCanonicalID.account(
        profileID: input.manifest.profileID, sourceAccountID: uid)
      let name = literal(asset, MoneyManagerV19Vocabulary.nameAliases).flatMap {
        $0.isEmpty ? nil : $0
      } ?? uid
      let state = running[uid] ?? Running(sum: zero)
      let accountCurrencyUID = literal(asset, MoneyManagerV19Vocabulary.currencyUIDAliases)
        .flatMap { $0.isEmpty ? nil : $0 }
      var currencyUnit = accountCurrencyUID.flatMap { isoByCurrencyUID[$0] }
      var figure: MoneyManagerV19SourceBalances.Account.Figure
      if let reason = state.unavailable {
        figure = .unavailable(reason: reason)
      } else if let accountCurrencyUID,
        state.rowCurrencies.contains(where: { $0 != accountCurrencyUID })
      {
        figure = .unavailable(reason: "entries in another currency are not converted")
      } else if accountCurrencyUID == nil, state.rowCurrencies.count > 1 {
        figure = .unavailable(reason: "entries in more than one currency")
      } else {
        figure = .amount(state.sum.description)
      }
      if currencyUnit == nil, let only = state.rowCurrencies.first, state.rowCurrencies.count == 1 {
        currencyUnit = isoByCurrencyUID[only]
      }
      if currencyUnit == nil, accountCurrencyUID == nil, isoByCurrencyUID.count == 1 {
        currencyUnit = isoByCurrencyUID.values.first
      }
      if currencyUnit == nil, case .amount = figure {
        figure = .unavailable(reason: "the account's currency is not in the backup")
      }
      let shownState = literal(asset, shownStateAliases) ?? ""
      let order = literal(asset, displayOrderAliases).flatMap(Int.init) ?? index
      accounts.append(
        .init(
          sourceAccountUID: uid, ledgerAccountID: ledgerAccountID, name: name,
          currencyUnit: currencyUnit, figure: figure,
          deletedInSource: shownState == deletedAccountState,
          hiddenInSource: shownState == hiddenAccountState,
          excludedFromTotalsInSource: literal(asset, excludedFromTotalsAliases)
            == excludedFromTotalsFlag,
          countedRowCount: state.counted, notImportedRowCount: state.notImported,
          displayOrder: order))
    }
    accounts.sort {
      ($0.displayOrder, $0.name, $0.sourceAccountUID) < ($1.displayOrder, $1.name, $1.sourceAccountUID)
    }
    return .init(accounts: accounts, throughDay: throughDay, countedRowCount: countedRows)
  }

  private static func literal(_ record: MoneyManagerV19SourceRecord, _ aliases: [String]) -> String? {
    for alias in aliases {
      guard let field = record.fields.first(where: { $0.name == alias }) else { continue }
      return MoneyManagerV19Vocabulary.mappingLiteral(
        storageClass: field.storageClass, payload: field.payload, value: field.value)
    }
    return nil
  }

  private static func isCivilDay(_ literal: String) -> Bool {
    let parts = literal.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]),
      let day = Int(parts[2])
    else { return false }
    return (try? SourceLocalDate(year: year, month: month, day: day)) != nil
  }
}
