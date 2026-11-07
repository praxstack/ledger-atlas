import Foundation
import LedgerCore
import LedgerStore

/// Every account's balance in Ledger Atlas beside the figure Money Manager shows for it, taken
/// the moment an import commits (#172). The Money Manager figure comes from the backup's rows
/// by Money Manager's own rule (`MoneyManagerV19SourceBalances`), never from the ledger that
/// was just written, so an equal row is evidence that the import mapped every entry the way
/// the phone counts it.
///
/// The receipt is a record of that moment: it is saved beside the ledger and shown again from
/// Import Review, and it never changes when the ledger is edited later.
public struct ImportBalanceReceipt: Codable, Equatable, Sendable {
  public static let currentFormatVersion = 1

  public struct Row: Codable, Equatable, Identifiable, Sendable {
    public enum Outcome: Codable, Equatable, Sendable {
      /// Ledger Atlas and Money Manager agree to the minor unit.
      case equal
      /// They differ; `difference` is Ledger Atlas minus Money Manager, an exact decimal literal.
      case differs(difference: String)
      /// The backup carries no figure for this account; the reason says why.
      case notStored(reason: String)
      /// Money Manager has this account but the ledger does not.
      case notInLedger
      /// Money Manager keeps the account in another currency (`sourceCurrencyUnit`), so the
      /// two figures cannot be compared. Counted as a difference, never as a match.
      case differentCurrency
    }

    public var id: String { ledgerAccountID }
    public let ledgerAccountID: String
    public let name: String
    public let currencyUnit: String
    /// Ledger Atlas's balance as an exact decimal literal; nil when the ledger has no such
    /// account.
    public let ledgerBalance: String?
    /// Money Manager's figure as an exact decimal literal, when the backup yields one.
    public let sourceBalance: String?
    public let outcome: Outcome
    public let hiddenInSource: Bool
    public let excludedFromTotalsInSource: Bool
    public let deletedInSource: Bool
    /// Entries Money Manager counts that stayed preserved source instead of being imported.
    public let notImportedEntryCount: Int
    /// Entries made with a linked debit card that Money Manager counts in this account.
    public let debitCardEntryCount: Int
    /// For a debit card: the account its entries count in, by name.
    public let movesAccountName: String?
    /// Why Money Manager's figure can't be worked out, whatever the outcome. Kept apart from
    /// the outcome so an account missing from the ledger still says why it has no figure.
    public let sourceUnavailableReason: String?
    /// The currency of `sourceBalance` when it is not `currencyUnit`.
    public let sourceCurrencyUnit: String?

    public init(
      ledgerAccountID: String, name: String, currencyUnit: String, ledgerBalance: String?,
      sourceBalance: String?, outcome: Outcome, hiddenInSource: Bool = false,
      excludedFromTotalsInSource: Bool = false, deletedInSource: Bool = false,
      notImportedEntryCount: Int = 0, debitCardEntryCount: Int = 0, movesAccountName: String? = nil,
      sourceUnavailableReason: String? = nil, sourceCurrencyUnit: String? = nil
    ) {
      self.ledgerAccountID = ledgerAccountID
      self.name = name
      self.currencyUnit = currencyUnit
      self.ledgerBalance = ledgerBalance
      self.sourceBalance = sourceBalance
      self.outcome = outcome
      self.hiddenInSource = hiddenInSource
      self.excludedFromTotalsInSource = excludedFromTotalsInSource
      self.deletedInSource = deletedInSource
      self.notImportedEntryCount = notImportedEntryCount
      self.debitCardEntryCount = debitCardEntryCount
      self.movesAccountName = movesAccountName
      if case .notStored(let reason) = outcome {
        self.sourceUnavailableReason = sourceUnavailableReason ?? reason
      } else {
        self.sourceUnavailableReason = sourceUnavailableReason
      }
      self.sourceCurrencyUnit = sourceCurrencyUnit
    }

    public var isEqual: Bool { outcome == .equal }
    /// How Money Manager itself marks the account, in words.
    public var sourceMarks: [String] {
      var marks: [String] = []
      if deletedInSource { marks.append("deleted in Money Manager") }
      if hiddenInSource { marks.append("hidden in Money Manager") }
      if excludedFromTotalsInSource { marks.append("left out of Money Manager's totals") }
      return marks
    }
    public var isDifferent: Bool {
      switch outcome {
      case .differs, .differentCurrency: true
      default: false
      }
    }
    /// The unit `sourceBalance` is in.
    public var sourceUnit: String { sourceCurrencyUnit ?? currencyUnit }
    public var isMissingFromLedger: Bool { outcome == .notInLedger }
  }

  public let formatVersion: Int
  /// When the import committed, as a UTC epoch in milliseconds.
  public let importedAtEpochMilliseconds: Int64
  /// The newest entry day in the backup, `YYYY-MM-DD`, which is what the figures are as of.
  public let throughDay: String?
  /// Plain words for where the Money Manager figure comes from, shown on the receipt.
  public let sourceRule: String
  public let rows: [Row]

  public static let v19SourceRule =
    "A Money Manager backup stores no balances. Each Money Manager figure is the backup's own entries added up the way the app counts them (income, transfers in and balance increases add; expenses, transfers out and balance decreases subtract), read from the backup, never from this ledger."

  public init(
    formatVersion: Int = Self.currentFormatVersion, importedAtEpochMilliseconds: Int64,
    throughDay: String?, sourceRule: String = Self.v19SourceRule, rows: [Row]
  ) {
    self.formatVersion = formatVersion
    self.importedAtEpochMilliseconds = importedAtEpochMilliseconds
    self.throughDay = throughDay
    self.sourceRule = sourceRule
    self.rows = rows
  }

  public var equalCount: Int { rows.filter(\.isEqual).count }
  public var differingCount: Int { rows.filter(\.isDifferent).count }
  public var missingFromLedgerCount: Int { rows.filter(\.isMissingFromLedger).count }
  public var notStoredCount: Int {
    rows.count - equalCount - differingCount - missingFromLedgerCount
  }
  /// True when every account that has a figure matches and none is missing from the ledger.
  public var allMatch: Bool { differingCount == 0 && missingFromLedgerCount == 0 }

  /// Builds the receipt from the source figures and the ledger as read right after the commit.
  /// Ledger balances come from `LedgerAccountBalanceSheet`, the same arithmetic every screen
  /// uses, so what the receipt says equal is what the Accounts screen shows.
  public static func build(
    source: MoneyManagerV19SourceBalances, accounts: [LedgerAccount],
    transactions: [LedgerTransactionSnapshot], importedAt: UTCInstant
  ) throws -> ImportBalanceReceipt {
    let sheet = try LedgerAccountBalanceSheet(accounts: accounts, transactions: transactions)
    let accountsByID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var rows: [Row] = []
    for sourceAccount in source.accounts {
      guard let account = accountsByID[sourceAccount.ledgerAccountID],
        let balance = sheet.balances[account.id]
      else {
        // Listed, not skipped: an account the phone shows and the ledger lacks is a finding.
        var sourceLiteral: String?
        var reason: String?
        switch sourceAccount.figure {
        case .amount(let literal):
          sourceLiteral = (try? ExactDecimal(literal))?.description
          if sourceLiteral == nil { reason = "the figure is not an exact decimal" }
        case .unavailable(let why):
          reason = why
        }
        rows.append(
          Row(
            ledgerAccountID: sourceAccount.ledgerAccountID, name: sourceAccount.name,
            currencyUnit: sourceAccount.currencyUnit ?? "", ledgerBalance: nil,
            sourceBalance: sourceLiteral, outcome: .notInLedger,
            hiddenInSource: sourceAccount.hiddenInSource,
            excludedFromTotalsInSource: sourceAccount.excludedFromTotalsInSource,
            deletedInSource: sourceAccount.deletedInSource,
            notImportedEntryCount: sourceAccount.notImportedRowCount,
            debitCardEntryCount: sourceAccount.debitCardRowCount,
            movesAccountName: sourceAccount.movesAccountName, sourceUnavailableReason: reason))
        continue
      }
      let ledgerLiteral = balance.amount.description
      var sourceLiteral: String?
      var sourceCurrencyUnit: String?
      let outcome: Row.Outcome
      switch sourceAccount.figure {
      case .unavailable(let reason):
        outcome = .notStored(reason: reason)
      case .amount(let literal):
        if let unit = sourceAccount.currencyUnit, unit != account.currencyUnit,
          let figure = try? ExactDecimal(literal)
        {
          sourceLiteral = figure.description
          sourceCurrencyUnit = unit
          outcome = .differentCurrency
        } else if let figure = try? ExactDecimal(literal) {
          sourceLiteral = figure.description
          let difference = try balance.amount.subtracting(figure)
          outcome = figure == balance.amount ? .equal : .differs(difference: difference.description)
        } else {
          outcome = .notStored(reason: "the figure is not an exact decimal")
        }
      }
      rows.append(
        Row(
          ledgerAccountID: account.id, name: sourceAccount.name,
          currencyUnit: account.currencyUnit, ledgerBalance: ledgerLiteral,
          sourceBalance: sourceLiteral, outcome: outcome,
          hiddenInSource: sourceAccount.hiddenInSource,
          excludedFromTotalsInSource: sourceAccount.excludedFromTotalsInSource,
          deletedInSource: sourceAccount.deletedInSource,
          notImportedEntryCount: sourceAccount.notImportedRowCount,
          debitCardEntryCount: sourceAccount.debitCardRowCount,
          movesAccountName: sourceAccount.movesAccountName,
          sourceCurrencyUnit: sourceCurrencyUnit))
    }
    return ImportBalanceReceipt(
      importedAtEpochMilliseconds: importedAt.epochMilliseconds, throughDay: source.throughDay,
      rows: rows)
  }

  // MARK: Saved as PDF

  /// The receipt as plain lines for the statement exporter. Figures are the exact literals the
  /// receipt holds, with their currency code, so the PDF says exactly what was compared.
  public func statementLines() -> [String] {
    var lines = ["Ledger Atlas balance receipt", "Money Manager import"]
    if let throughDay { lines.append("Figures as of \(throughDay), the newest entry in the backup") }
    lines.append("Checked when the import committed: \(Self.isoDay(importedAtEpochMilliseconds))")
    lines.append("")
    var counts = "\(equalCount) match, \(differingCount) differ, \(notStoredCount) without a Money Manager figure"
    if missingFromLedgerCount > 0 { counts += ", \(missingFromLedgerCount) not in this ledger" }
    lines.append(counts)
    for row in rows {
      lines.append("")
      let marks = row.sourceMarks
      lines.append(marks.isEmpty ? row.name : "\(row.name) (\(marks.joined(separator: ", ")))")
      lines.append(
        "  Ledger Atlas: \(row.ledgerBalance.map { "\($0) \(row.currencyUnit)" } ?? "not in this ledger")")
      lines.append(
        "  Money Manager: \(row.sourceBalance.map { "\($0) \(row.sourceUnit)" } ?? "not stored in the backup")")
      switch row.outcome {
      case .equal:
        lines.append("  Result: matches")
      case .differs(let difference):
        lines.append("  Result: differs by \(difference) \(row.currencyUnit) (Ledger Atlas minus Money Manager)")
      case .notStored(let reason):
        lines.append("  Result: no Money Manager figure, because \(reason)")
      case .notInLedger:
        lines.append("  Result: the account is in Money Manager but not in this ledger")
        if let reason = row.sourceUnavailableReason {
          lines.append("  No Money Manager figure either, because \(reason)")
        }
      case .differentCurrency:
        lines.append(
          "  Result: differs, Money Manager keeps this account in \(row.sourceUnit), this ledger in \(row.currencyUnit)")
      }
      if row.debitCardEntryCount > 0 {
        lines.append(
          "  Includes \(row.debitCardEntryCount) \(row.debitCardEntryCount == 1 ? "entry" : "entries") made with a linked debit card")
      }
      if row.notImportedEntryCount > 0 {
        lines.append(
          "  Money Manager also counts \(row.notImportedEntryCount) \(row.notImportedEntryCount == 1 ? "entry" : "entries") kept as preserved source, not imported")
      }
    }
    lines += ["", sourceRule]
    return lines
  }

  private static func isoDay(_ epochMilliseconds: Int64) -> String {
    let seconds = epochMilliseconds / 1_000
    let days = Int((seconds - (seconds % 86_400 + 86_400) % 86_400) / 86_400)
    // Civil-from-days (Howard Hinnant), in UTC.
    let z = days + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let day = doy - (153 * mp + 2) / 5 + 1
    let month = mp < 10 ? mp + 3 : mp - 9
    let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
    return String(format: "%04d-%02d-%02d UTC", year, month, day)
  }

  // MARK: Sidecar file

  /// The receipt lives beside its ledger: `<ledger>.balance-receipt.json`.
  public static let sidecarSuffix = ".balance-receipt.json"

  public static func sidecarURL(forLedgerAt ledgerURL: URL) -> URL {
    URL(fileURLWithPath: ledgerURL.path + sidecarSuffix)
  }

  /// Larger sidecars are refused when written or read.
  public static let maximumSidecarBytes = 4 * 1_024 * 1_024

  /// Saved owner-only (0600) from the moment it exists, without following a symlink put where
  /// the sidecar goes, and replaced in one step.
  public func write(besideLedgerAt ledgerURL: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    try LedgerPrivateFile.write(
      try encoder.encode(self), at: Self.sidecarURL(forLedgerAt: ledgerURL),
      maximumSize: Self.maximumSidecarBytes)
  }

  /// The receipt saved beside `ledgerURL`, or nil when there is none or it cannot be read.
  /// A symlink, a folder or an oversized file is refused before anything is read. A receipt
  /// from a newer app is ignored rather than guessed at.
  public static func read(besideLedgerAt ledgerURL: URL) -> ImportBalanceReceipt? {
    guard
      let data = try? LedgerPrivateFile.read(
        at: sidecarURL(forLedgerAt: ledgerURL), maximumSize: maximumSidecarBytes),
      let receipt = try? JSONDecoder().decode(ImportBalanceReceipt.self, from: data),
      receipt.formatVersion == currentFormatVersion
    else { return nil }
    return receipt
  }

  /// `read(besideLedgerAt:)`, kept only when it describes the ledger that is open: every
  /// account the receipt found in the ledger must still be there. A sidecar left beside a
  /// ledger that was replaced by another backup names accounts the new ledger lacks, so it is
  /// not shown as that ledger's receipt.
  public static func read(
    besideLedgerAt ledgerURL: URL, accounts: [LedgerAccount]
  ) -> ImportBalanceReceipt? {
    guard let receipt = read(besideLedgerAt: ledgerURL) else { return nil }
    return receipt.describes(accounts: accounts) ? receipt : nil
  }

  /// True when the receipt found at least one account in the ledger and every such account is
  /// among `accounts`. A receipt that found none can't be tied to any ledger, so it is not
  /// shown again after the import that made it.
  public func describes(accounts: [LedgerAccount]) -> Bool {
    let ids = Set(accounts.map(\.id))
    let found = rows.filter { $0.ledgerBalance != nil }
    return !found.isEmpty && found.allSatisfy { ids.contains($0.ledgerAccountID) }
  }

  public static func removeSidecar(besideLedgerAt ledgerURL: URL) {
    try? LedgerPrivateFile.write(
      nil, at: sidecarURL(forLedgerAt: ledgerURL), maximumSize: maximumSidecarBytes)
  }
}
