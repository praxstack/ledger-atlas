import CSQLite
import Foundation
import LedgerCore
import LedgerStore
import Testing

@testable import MMImport

/// #172: after an import, every account's Ledger Atlas balance beside Money Manager's own
/// figure for it. The Money Manager figure is the backup's rows added up by the phone's rule,
/// read from the staged source; it is never the ledger's own sum.
@Suite("Balance-match receipt")
struct ImportBalanceReceiptTests {
  @Test("a synthetic v19 import yields an equal row, a differing row explained by preserved legs, and the as-of day")
  func receiptOnTheSyntheticFixture() throws {
    try withImportedFixture { imported in
      let receipt = imported.receipt
      #expect(receipt.throughDay == "2025-02-03")
      #expect(receipt.rows.count == 2)
      #expect(receipt.rows.map(\.name) == ["Wallet", "Bank"])

      // Bank: income 100, a balance decrease recorded as an expense 2, a quiet balance increase
      // 4 and a transfer in of 40 reach the same 142 on both sides. Figures are exact decimal
      // literals in canonical form (no trailing zeros); screens format them.
      let bank = try #require(receipt.rows.first { $0.name == "Bank" })
      #expect(bank.ledgerBalance == "142")
      #expect(bank.sourceBalance == "142")
      #expect(bank.outcome == .equal)
      #expect(bank.currencyUnit == "USD")
      #expect(bank.notImportedEntryCount == 0)

      // Wallet: Money Manager also counts the orphan transfer leg (−5) and the same-account
      // pair (−6, +6) that the import keeps as preserved source, so the phone shows −55.50
      // where the ledger holds −50.50 (literals −55.5 and −50.5). The receipt says both figures, the difference and why.
      let wallet = try #require(receipt.rows.first { $0.name == "Wallet" })
      #expect(wallet.ledgerBalance == "-50.5")
      #expect(wallet.sourceBalance == "-55.5")
      #expect(wallet.outcome == .differs(difference: "5"))
      #expect(wallet.notImportedEntryCount == 3)

      #expect(receipt.equalCount == 1)
      #expect(receipt.differingCount == 1)
      #expect(receipt.notStoredCount == 0)
      #expect(!receipt.allMatch)
    }
  }

  @Test("one minor unit of difference is reported, signed as ledger minus Money Manager")
  func oneMinorUnitDifference() throws {
    try withImportedFixture { imported in
      let bank = try #require(imported.source.accounts.first { $0.name == "Bank" })
      let nudged = MoneyManagerV19SourceBalances(
        accounts: [
          .init(
            sourceAccountUID: bank.sourceAccountUID, ledgerAccountID: bank.ledgerAccountID,
            name: bank.name, currencyUnit: bank.currencyUnit, figure: .amount("142.01"),
            deletedInSource: false, hiddenInSource: false, excludedFromTotalsInSource: false,
            countedRowCount: bank.countedRowCount, notImportedRowCount: 0, displayOrder: 0)
        ], throughDay: "2025-02-03", countedRowCount: 4)
      let receipt = try ImportBalanceReceipt.build(
        source: nudged, accounts: imported.snapshot.accounts,
        transactions: imported.snapshot.transactions, importedAt: UTCInstant(epochMilliseconds: 1))
      let row = try #require(receipt.rows.first)
      #expect(row.outcome == .differs(difference: "-0.01"))
      #expect(row.ledgerBalance == "142")
      #expect(row.sourceBalance == "142.01")
      #expect(receipt.differingCount == 1)
    }
  }

  @Test("an account whose figure the backup cannot yield says so, and source marks carry over")
  func missingFigureAndSourceMarks() throws {
    try withImportedFixture(
      extraSQL: """
        INSERT INTO ASSETS (uid, NIC_NAME, ZDATA, ZDATA2, groupUid, currencyUid, ORDERSEQ)
          VALUES ('acct-c', 'Old Card', '3', '1', '1', 'cur-main', 3),
                 ('acct-d', 'Closed', '1', '0', '1', 'cur-main', 4);
        INSERT INTO INOUTCOME
          (uid, assetUid, ctgUid, DO_TYPE, ZMONEY, IN_ZMONEY, AMOUNT_ACCOUNT, ZDATE, WDATE,
           ZCONTENT, ZDATA, CARDDIVIDMONTH, currencyUid, UTIME)
        VALUES
          ('tx-odd-amount', 'acct-c', 'cat-food', '1', 'twelve', 'twelve', 0.0,
           '1738547700000', '2025-02-04', 'odd', '', '0', 'cur-main', 1738547700000),
          ('tx-deleted', 'acct-d', 'cat-food', '1', '9.00', '9.00', 9.0,
           '1738547800000', '2025-02-05', 'gone', '', '0', 'cur-main', 1738547800000);
        UPDATE INOUTCOME SET IS_DEL = 1 WHERE uid = 'tx-deleted';
        """
    ) { imported in
      let receipt = imported.receipt
      #expect(receipt.rows.map(\.name) == ["Wallet", "Bank", "Old Card", "Closed"])
      let oldCard = try #require(receipt.rows.first { $0.name == "Old Card" })
      #expect(oldCard.sourceBalance == nil)
      #expect(oldCard.outcome == .notStored(reason: "an entry's amount is not an exact decimal"))
      #expect(oldCard.hiddenInSource)
      #expect(oldCard.excludedFromTotalsInSource)
      #expect(!oldCard.deletedInSource)
      // A deleted row counts for neither side; the deleted account is listed and marked.
      let closed = try #require(receipt.rows.first { $0.name == "Closed" })
      #expect(closed.outcome == .equal)
      #expect(closed.ledgerBalance == "0")
      #expect(closed.sourceBalance == "0")
      #expect(closed.deletedInSource)
      // The deleted row's day does not move the as-of day; the odd row's does.
      #expect(receipt.throughDay == "2025-02-04")
      #expect(receipt.notStoredCount == 1)
    }
  }

  @Test("a debit card's entries count in the account that pays it, as Money Manager shows")
  func debitCardMovesItsPayingAccount() throws {
    try withImportedFixture(
      extraSQL: """
        INSERT INTO ASSETGROUP (uid, IS_DEL, ACC_GROUP_NAME, TYPE, ORDERSEQ)
          VALUES ('3', 0, 'Debit Card', 3, 3);
        INSERT INTO ASSETS (uid, NIC_NAME, ZDATA, groupUid, currencyUid, ORDERSEQ, cardAssetUid)
          VALUES ('acct-debit', 'Bank Debit', '0', '3', 'cur-main', 3, 'acct-b');
        INSERT INTO INOUTCOME
          (uid, assetUid, ctgUid, DO_TYPE, ZMONEY, IN_ZMONEY, AMOUNT_ACCOUNT, ZDATE, WDATE,
           ZCONTENT, ZDATA, CARDDIVIDMONTH, currencyUid, UTIME)
        VALUES
          ('tx-debit', 'acct-debit', 'cat-food', '1', '7.00', '7.00', 7.0,
           '1738547700000', '2025-02-03', 'card', '', '0', 'cur-main', 1738547700000);
        """
    ) { imported in
      let source = try #require(imported.source.accounts.first { $0.name == "Bank" })
      #expect(source.figure == .amount("135"))
      #expect(source.debitCardRowCount == 1)
      let card = try #require(imported.source.accounts.first { $0.name == "Bank Debit" })
      #expect(card.movesAccountName == "Bank")
      #expect(
        card.figure
          == .unavailable(
            reason: "Money Manager keeps no balance for a debit card; its entries count in Bank"))

      // The importer still books the card's entry on the card (#207), so the receipt shows
      // the gap instead of a false match.
      let bank = try #require(imported.receipt.rows.first { $0.name == "Bank" })
      #expect(bank.ledgerBalance == "142")
      #expect(bank.sourceBalance == "135")
      #expect(bank.outcome == .differs(difference: "7"))
      #expect(bank.debitCardEntryCount == 1)
      let cardRow = try #require(imported.receipt.rows.first { $0.name == "Bank Debit" })
      #expect(cardRow.sourceBalance == nil)
      #expect(cardRow.movesAccountName == "Bank")
      #expect(imported.receipt.statementLines().contains("  Includes 1 entry made with a linked debit card"))
    }
  }

  @Test("an account Money Manager has and the ledger lacks is listed, not skipped")
  func accountMissingFromTheLedger() throws {
    try withImportedFixture { imported in
      let missing = MoneyManagerV19SourceBalances(
        accounts: [
          .init(
            sourceAccountUID: "gone", ledgerAccountID: "not-in-ledger", name: "Gone",
            currencyUnit: "USD", figure: .amount("3.50"), deletedInSource: false,
            hiddenInSource: false, excludedFromTotalsInSource: false, countedRowCount: 1,
            notImportedRowCount: 1, displayOrder: 0)
        ], throughDay: nil, countedRowCount: 1)
      let receipt = try ImportBalanceReceipt.build(
        source: missing, accounts: imported.snapshot.accounts,
        transactions: imported.snapshot.transactions, importedAt: UTCInstant(epochMilliseconds: 1))
      let row = try #require(receipt.rows.first)
      #expect(row.outcome == .notInLedger)
      #expect(row.ledgerBalance == nil)
      #expect(row.sourceBalance == "3.5")
      #expect(receipt.missingFromLedgerCount == 1)
      #expect(receipt.notStoredCount == 0)
      #expect(!receipt.allMatch)
      #expect(receipt.statementLines().contains("  Ledger Atlas: not in this ledger"))
      #expect(row.sourceUnavailableReason == nil)
    }
  }

  @Test("a missing account without a Money Manager figure keeps the reason")
  func missingAccountKeepsTheReason() throws {
    try withImportedFixture { imported in
      let missing = MoneyManagerV19SourceBalances(
        accounts: [
          .init(
            sourceAccountUID: "gone", ledgerAccountID: "not-in-ledger", name: "Gone",
            currencyUnit: "USD", figure: .unavailable(reason: "entries in more than one currency"),
            deletedInSource: false, hiddenInSource: false, excludedFromTotalsInSource: false,
            countedRowCount: 2, notImportedRowCount: 2, displayOrder: 0)
        ], throughDay: nil, countedRowCount: 2)
      let receipt = try ImportBalanceReceipt.build(
        source: missing, accounts: imported.snapshot.accounts,
        transactions: imported.snapshot.transactions, importedAt: UTCInstant(epochMilliseconds: 1))
      let row = try #require(receipt.rows.first)
      #expect(row.outcome == .notInLedger)
      #expect(row.sourceUnavailableReason == "entries in more than one currency")
      #expect(
        receipt.statementLines().contains(
          "  No Money Manager figure either, because entries in more than one currency"))
    }
  }

  @Test("a figure in another currency is a difference, never a match, and keeps its amount")
  func currencyMismatchIsADifference() throws {
    try withImportedFixture { imported in
      let bank = try #require(imported.source.accounts.first { $0.name == "Bank" })
      let euros = MoneyManagerV19SourceBalances(
        accounts: [
          .init(
            sourceAccountUID: bank.sourceAccountUID, ledgerAccountID: bank.ledgerAccountID,
            name: bank.name, currencyUnit: "EUR", figure: .amount("142.00"),
            deletedInSource: false, hiddenInSource: false, excludedFromTotalsInSource: false,
            countedRowCount: bank.countedRowCount, notImportedRowCount: 0, displayOrder: 0)
        ], throughDay: nil, countedRowCount: 4)
      let receipt = try ImportBalanceReceipt.build(
        source: euros, accounts: imported.snapshot.accounts,
        transactions: imported.snapshot.transactions, importedAt: UTCInstant(epochMilliseconds: 1))
      let row = try #require(receipt.rows.first)
      #expect(row.outcome == .differentCurrency)
      #expect(row.sourceBalance == "142")
      #expect(row.sourceUnit == "EUR")
      #expect(row.currencyUnit == "USD")
      #expect(receipt.differingCount == 1)
      #expect(!receipt.allMatch)
      let lines = receipt.statementLines()
      #expect(lines.contains("  Money Manager: 142 EUR"))
      #expect(
        lines.contains("  Result: differs, Money Manager keeps this account in EUR, this ledger in USD"))
    }
  }

  @Test("a saved receipt is shown only for the ledger it describes")
  func receiptIsBoundToItsLedger() throws {
    try withImportedFixture { imported in
      let ledger = imported.canonicalURL
      try imported.receipt.write(besideLedgerAt: ledger)
      #expect(
        ImportBalanceReceipt.read(besideLedgerAt: ledger, accounts: imported.snapshot.accounts)
          == imported.receipt)
      // A replacement ledger without these accounts does not inherit the receipt.
      let other = try LedgerAccount(
        id: StableLedgerID.account(
          origin: LedgerOrigin(id: String(repeating: "7", count: 64), label: "other"),
          localKey: String(repeating: "a", count: 64)),
        name: "Other", currencyUnit: "USD",
        origin: LedgerOrigin(id: String(repeating: "7", count: 64), label: "other"))
      #expect(ImportBalanceReceipt.read(besideLedgerAt: ledger, accounts: [other]) == nil)
      #expect(!imported.receipt.describes(accounts: []))
      // A receipt that found no account in its ledger is tied to none, so no ledger takes it.
      let unbound = ImportBalanceReceipt(
        importedAtEpochMilliseconds: 0, throughDay: nil,
        rows: [
          .init(
            ledgerAccountID: "gone", name: "Gone", currencyUnit: "USD", ledgerBalance: nil,
            sourceBalance: "1", outcome: .notInLedger)
        ])
      #expect(!unbound.describes(accounts: imported.snapshot.accounts))
    }
  }

  @Test("the as-of day is a padded calendar day, so a short month cannot sort after November")
  func asOfDayIsNormalized() {
    #expect(MoneyManagerV19BalanceOracle.civilDay("2025-2-03") == "2025-02-03")
    #expect(MoneyManagerV19BalanceOracle.civilDay("2025-11-01") == "2025-11-01")
    #expect(MoneyManagerV19BalanceOracle.civilDay("2025-02-30") == nil)
    #expect(MoneyManagerV19BalanceOracle.civilDay("yesterday") == nil)
    #expect(
      MoneyManagerV19BalanceOracle.civilDay("2025-11-01")! > MoneyManagerV19BalanceOracle.civilDay("2025-2-03")!)
  }

  @Test("an account whose entries add up past what can be held exactly has no figure; the import still prepares")
  func overflowLeavesTheFigureUnavailable() throws {
    let huge = String(repeating: "9", count: 120)
    try withImportedFixture(
      extraSQL: """
        INSERT INTO ASSETS (uid, NIC_NAME, ZDATA, groupUid, currencyUid, ORDERSEQ)
          VALUES ('acct-big', 'Big', '0', '1', 'cur-main', 3);
        INSERT INTO INOUTCOME
          (uid, assetUid, ctgUid, DO_TYPE, ZMONEY, IN_ZMONEY, AMOUNT_ACCOUNT, ZDATE, WDATE,
           ZCONTENT, ZDATA, CARDDIVIDMONTH, currencyUid, UTIME)
        VALUES
          ('tx-big-1', 'acct-big', 'cat-salary', '0', '\(huge)', '\(huge)', 0.0,
           '1738547700000', '2025-02-03', 'big', '', '0', 'cur-main', 1738547700000),
          ('tx-big-2', 'acct-big', 'cat-salary', '0', '0.\(String(repeating: "1", count: 60))',
           '0.1', 0.0, '1738547700000', '2025-02-03', 'big', '', '0', 'cur-main', 1738547700000);
        """,
      allowUnbuiltReceipt: true
    ) { imported in
      let big = try #require(imported.source.accounts.first { $0.name == "Big" })
      #expect(big.figure == .unavailable(reason: "the entries add up to more than can be held exactly"))
    }
  }

  @Test("the sidecar is owner-only from the start and a symlink in its place is refused")
  func sidecarIsPrivate() throws {
    try withImportedFixture { imported in
      let ledger = imported.canonicalURL
      try imported.receipt.write(besideLedgerAt: ledger)
      let sidecar = ImportBalanceReceipt.sidecarURL(forLedgerAt: ledger)
      let mode = try #require(
        try FileManager.default.attributesOfItem(atPath: sidecar.path)[.posixPermissions] as? NSNumber)
      #expect(mode.intValue & 0o777 == 0o600)

      ImportBalanceReceipt.removeSidecar(besideLedgerAt: ledger)
      let elsewhere = ledger.deletingLastPathComponent().appendingPathComponent("elsewhere.json")
      try imported.receipt.write(besideLedgerAt: ledger.deletingLastPathComponent()
        .appendingPathComponent("other.sqlite"))
      try FileManager.default.moveItem(
        at: ImportBalanceReceipt.sidecarURL(
          forLedgerAt: ledger.deletingLastPathComponent().appendingPathComponent("other.sqlite")),
        to: elsewhere)
      try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: elsewhere)
      #expect(ImportBalanceReceipt.read(besideLedgerAt: ledger) == nil)

      // A FIFO with no writer is refused at once instead of hanging the open.
      try FileManager.default.removeItem(at: sidecar)
      #expect(mkfifo(sidecar.path, 0o600) == 0)
      #expect(ImportBalanceReceipt.read(besideLedgerAt: ledger) == nil)
    }
  }

  @Test("the receipt round-trips through its sidecar file and ignores a newer format")
  func sidecarRoundTrip() throws {
    try withImportedFixture { imported in
      let ledger = imported.canonicalURL
      try imported.receipt.write(besideLedgerAt: ledger)
      let sidecar = ImportBalanceReceipt.sidecarURL(forLedgerAt: ledger)
      #expect(FileManager.default.fileExists(atPath: sidecar.path))
      #expect(ImportBalanceReceipt.read(besideLedgerAt: ledger) == imported.receipt)

      let newer = ImportBalanceReceipt(
        formatVersion: ImportBalanceReceipt.currentFormatVersion + 1,
        importedAtEpochMilliseconds: 0, throughDay: nil, rows: [])
      try newer.write(besideLedgerAt: ledger)
      #expect(ImportBalanceReceipt.read(besideLedgerAt: ledger) == nil)

      ImportBalanceReceipt.removeSidecar(besideLedgerAt: ledger)
      #expect(!FileManager.default.fileExists(atPath: sidecar.path))
      #expect(ImportBalanceReceipt.read(besideLedgerAt: ledger) == nil)
    }
  }

  @Test("the PDF lines name both figures, the result, the marks and where the figure comes from")
  func statementLines() throws {
    try withImportedFixture { imported in
      let lines = imported.receipt.statementLines()
      #expect(lines.first == "Ledger Atlas balance receipt")
      #expect(lines.contains("Figures as of 2025-02-03, the newest entry in the backup"))
      #expect(lines.contains("Checked when the import committed: 2025-11-01 UTC"))
      #expect(lines.contains("1 match, 1 differ, 0 without a Money Manager figure"))
      #expect(lines.contains("  Ledger Atlas: -50.5 USD"))
      #expect(lines.contains("  Money Manager: -55.5 USD"))
      #expect(lines.contains("  Result: differs by 5 USD (Ledger Atlas minus Money Manager)"))
      #expect(
        lines.contains("  Money Manager also counts 3 entries kept as preserved source, not imported"))
      #expect(lines.contains("  Result: matches"))
      #expect(lines.last == ImportBalanceReceipt.v19SourceRule)
    }
    let marked = ImportBalanceReceipt(
      importedAtEpochMilliseconds: 0, throughDay: nil,
      rows: [
        .init(
          ledgerAccountID: "a", name: "Old Card", currencyUnit: "INR", ledgerBalance: "0",
          sourceBalance: nil, outcome: .notStored(reason: "an entry's amount is not an exact decimal"),
          hiddenInSource: true, excludedFromTotalsInSource: true)
      ])
    let lines = marked.statementLines()
    #expect(lines.contains("Old Card (hidden in Money Manager, left out of Money Manager's totals)"))
    #expect(lines.contains("  Money Manager: not stored in the backup"))
    #expect(lines.contains("Checked when the import committed: 1970-01-01 UTC"))
    #expect(!lines.contains { $0.hasPrefix("Figures as of") })
  }

  @Test("the workspace's commit result stays content-free; figures come from the explicit accessor")
  func figuresAreNotOnTheCommitResult() throws {
    try withImportedFixture { imported in
      #expect(
        Mirror(reflecting: imported.commitResult).children.compactMap(\.label).sorted()
          == ["eventCount", "status"])
      #expect(imported.source.accounts.count == 2)
      #expect(imported.source.countedRowCount == 11)
    }
  }
}

private struct ImportedFixture {
  let canonicalURL: URL
  let commitResult: ImportWorkspace.CommitResult
  let source: MoneyManagerV19SourceBalances
  let snapshot: LedgerStore.LedgerReadSnapshot
  let receipt: ImportBalanceReceipt
}

private func withImportedFixture(
  extraSQL: String? = nil, allowUnbuiltReceipt: Bool = false,
  _ body: (ImportedFixture) throws -> Void
) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("MM(synthetic).mmbak")
  try SyntheticV19Backup.write(to: source)
  if let extraSQL { try execute(at: source, sql: extraSQL) }
  let canonical = directory.appendingPathComponent("canonical.sqlite")
  let workspace = ImportWorkspace()
  let preparation = try workspace.prepare(
    .init(
      sourceURL: source, stagingDatabaseURL: directory.appendingPathComponent("stage.sqlite"),
      canonicalDatabaseURL: canonical, sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 19_800)))
  #expect(preparation.review.status == .prepared)
  let handle = try #require(preparation.preparedHandle)
  let result = try workspace.commit(handle, approval: workspace.approve(handle))
  #expect(result.status == .committed)
  let balances = workspace.sourceBalances(handle)
  let snapshot = try LedgerStore.openReadOnly(at: canonical).readSnapshot()
  let built = Result {
    try ImportBalanceReceipt.build(
      source: balances, accounts: snapshot.accounts, transactions: snapshot.transactions,
      importedAt: UTCInstant(epochMilliseconds: 1_762_000_000_000))
  }
  let receipt =
    allowUnbuiltReceipt
    ? ((try? built.get())
      ?? ImportBalanceReceipt(importedAtEpochMilliseconds: 0, throughDay: nil, rows: []))
    : try built.get()
  #expect(allowUnbuiltReceipt || receipt.importedAtEpochMilliseconds == 1_762_000_000_000)
  try body(
    ImportedFixture(
      canonicalURL: canonical, commitResult: result, source: balances, snapshot: snapshot,
      receipt: receipt))
}

private func execute(at url: URL, sql: String) throws {
  var database: OpaquePointer?
  guard
    sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
    let database
  else { throw SyntheticV19BackupError.sqlite }
  defer { sqlite3_close(database) }
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
    throw SyntheticV19BackupError.sqlite
  }
}
