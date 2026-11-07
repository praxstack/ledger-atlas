import CSQLite
import Foundation
import LedgerAdapterSemantics
import LedgerCore
import LedgerStore
import Testing

@testable import MMImport

/// #207: Money Manager keeps no balance for a Debit Card account. Its entries, transfer legs
/// and recurring rules move the account named in its `cardAssetUid`. Synthetic data only.
@Suite("Debit card entries move the paying account")
struct MoneyManagerV19DebitCardTests {
  /// A debit card paid by the bank; a debit card naming no existing account; a credit card that
  /// names the bank (credit cards keep their own entries).
  static let cardsSQL = """
    INSERT INTO ASSETGROUP (uid, IS_DEL, ACC_GROUP_NAME, TYPE, ORDERSEQ)
      VALUES ('2', 0, 'Credit Card', 2, 2), ('3', 0, 'Debit Card', 3, 3);
    INSERT INTO ASSETS (uid, NIC_NAME, ZDATA, groupUid, currencyUid, ORDERSEQ, cardAssetUid)
      VALUES ('acct-debit', 'Bank Debit', '0', '3', 'cur-main', 3, 'acct-b'),
             ('acct-debit-lost', 'Old Debit', '0', '3', 'cur-main', 4, 'acct-gone'),
             ('acct-credit', 'Credit', '0', '2', 'cur-main', 5, 'acct-b');
    INSERT INTO INOUTCOME
      (uid, assetUid, ctgUid, toAssetUid, txUidTrans, DO_TYPE, ZMONEY, IN_ZMONEY,
       AMOUNT_ACCOUNT, ZDATE, WDATE, ZCONTENT, ZDATA, CARDDIVIDMONTH, currencyUid, UTIME)
    VALUES
      ('tx-debit', 'acct-debit', 'cat-food', NULL, NULL, '1', '7.00', '7.00', 7.0,
       '1738547700000', '2025-02-03', 'card', '', '0', 'cur-main', 1738547700000),
      ('tx-card-out', 'acct-debit', NULL, 'acct-a', 'grp-card', '3', '20.00', '20.00', 20.0,
       '1738547800000', '2025-02-03', '', '', '0', 'cur-main', 1738547800000),
      ('tx-card-in', 'acct-a', NULL, 'acct-debit', 'grp-card', '4', '20.00', '20.00', 20.0,
       '1738547800000', '2025-02-03', '', '', '0', 'cur-main', 1738547800000),
      ('tx-top-up-out', 'acct-b', NULL, 'acct-debit', 'grp-top-up', '3', '15.00', '15.00', 15.0,
       '1738547900000', '2025-02-03', '', '', '0', 'cur-main', 1738547900000),
      ('tx-top-up-in', 'acct-debit', NULL, 'acct-b', 'grp-top-up', '4', '15.00', '15.00', 15.0,
       '1738547900000', '2025-02-03', '', '', '0', 'cur-main', 1738547900000),
      ('tx-lost', 'acct-debit-lost', 'cat-food', NULL, NULL, '1', '3.00', '3.00', 3.0,
       '1738548000000', '2025-02-03', '', '', '0', 'cur-main', 1738548000000),
      ('tx-credit', 'acct-credit', 'cat-food', NULL, NULL, '1', '9.00', '9.00', 9.0,
       '1738548100000', '2025-02-03', '', '', '0', 'cur-main', 1738548100000);
    INSERT INTO REPEATTRANSACTION (uid, IS_DEL, END_DATE, NEXT_DATE, DO_TYPE, REPEAT_TYPE,
      assetUid, ctgUid, currencyUid, AMOUNT_SUB, MEMO, PAYEE)
      VALUES ('rule-debit', 0, 0, 1741000000000, 1, 1, 'acct-debit', 'cat-food', 'cur-main', 4.0,
        '', 'synthetic');
    """

  @Test("the bank behind a debit card matches Money Manager, and the card keeps nothing")
  func debitCardEntriesMoveTheBank() throws {
    try withImport(extraSQL: Self.cardsSQL) { imported in
      let accounts = Dictionary(
        uniqueKeysWithValues: imported.snapshot.accounts.map { ($0.name, $0.id) })
      let bankID = try #require(accounts["Bank"])
      let cardID = try #require(accounts["Bank Debit"])
      // The card is still an account, with no entries of its own.
      let cardEffects = imported.effects.filter { $0.accountID == cardID }
      #expect(cardEffects.isEmpty)

      let bank = try #require(imported.receipt.rows.first { $0.name == "Bank" })
      #expect(bank.outcome == .equal)
      #expect(bank.ledgerBalance == bank.sourceBalance)
      let card = try #require(imported.receipt.rows.first { $0.name == "Bank Debit" })
      #expect(card.ledgerBalance == "0")

      // The card-to-wallet transfer is a bank-to-wallet transfer.
      let walletID = try #require(accounts["Wallet"])
      let cardTransfer = Set(
        imported.effects.filter { $0.amount.amount.rawLiteral == "20.00" }.map(\.accountID))
      #expect(cardTransfer == [bankID, walletID])
      // A top-up from the bank to its own card moves no money: both legs stay preserved.
      let topUps = imported.effects.filter { $0.amount.amount.rawLiteral == "15.00" }
      #expect(topUps.isEmpty)

      // A recurring rule on the card is a rule on the bank.
      let rulesOnBank = imported.snapshot.recurrenceRules.filter { $0.accountID == bankID }
      let rulesOnCard = imported.snapshot.recurrenceRules.filter { $0.accountID == cardID }
      #expect(rulesOnBank.count == 1)
      #expect(rulesOnCard.isEmpty)
    }
  }

  @Test("a debit card with no account behind it keeps its entries, and a credit card keeps its own")
  func unlinkedDebitAndCreditCardsKeepTheirEntries() throws {
    try withImport(extraSQL: Self.cardsSQL) { imported in
      let accounts = Dictionary(
        uniqueKeysWithValues: imported.snapshot.accounts.map { ($0.name, $0.id) })
      let lost = try #require(accounts["Old Debit"])
      let credit = try #require(accounts["Credit"])
      let lostEffects = imported.effects.filter { $0.accountID == lost }.map(\.amount.amount.rawLiteral)
      let creditEffects = imported.effects.filter { $0.accountID == credit }
        .map(\.amount.amount.rawLiteral)
      #expect(lostEffects == ["3.00"])
      #expect(creditEffects == ["9.00"])
      // The review says why the unlinked card's balance cannot be checked.
      let row = try #require(imported.receipt.rows.first { $0.name == "Old Debit" })
      #expect(row.sourceUnavailableReason == "this debit card names no account that pays it")
    }
  }

  @Test("the importer and the balance receipt read debit cards by one rule")
  func oneRuleForCards() {
    let cards = MoneyManagerV19Semantics.DebitCards(
      accounts: [
        ["uid": "bank"], ["uid": "debit", "groupUid": "g3", "cardAssetUid": "bank"],
        ["uid": "credit", "groupUid": "g2", "cardAssetUid": "bank"],
        ["uid": "self", "groupUid": "g3", "cardAssetUid": "self"],
        ["uid": "dangling", "groupUid": "g3", "cardAssetUid": "nowhere"],
        ["uid": "unsure", "groupUid": "gx", "cardAssetUid": "bank"],
      ],
      groups: [
        ["uid": "g2", "TYPE": "2"], ["uid": "g3", "TYPE": "3"],
        // A group listed twice with different types proves nothing.
        ["uid": "gx", "TYPE": "3"], ["uid": "gx", "TYPE": "1"],
      ])
    #expect(cards.payingAccountByCard == ["debit": "bank"])
    #expect(cards.cards == ["debit", "self", "dangling"])
    #expect(cards.movedAccount("debit") == "bank")
    #expect(cards.movedAccount("credit") == "credit")
  }
}

/// Replay of a persisted event's account proof (#207). Ledgers imported before the fix keep
/// the row's own `assetUid` as proof and stay valid.
@Suite("Debit card account proof on replay")
struct MoneyManagerV19DebitCardReplayTests {
  static let profile = "realbyte-android-sqlite-v19-observed"

  static func text(_ value: String) -> (CanonicalFieldStorageClass, Data) {
    (.text, Data(value.utf8))
  }

  static func sidecar(_ table: String, _ key: String, _ column: String, _ value: String)
    -> MoneyManagerV19Semantics.RetainedSidecar
  {
    .init(
      locator: SourceLocator(table: table, recordKey: key, columnName: column),
      storageClass: .text, payload: Data(value.utf8))
  }

  /// The `ASSETS` and `ASSETGROUP` rows a debit card's proof is read against.
  static func accounts(groupType: String = "3") -> MoneyManagerV19Semantics.RetainedAccounts {
    .init(fields: [
      sidecar("ASSETS", "1", "uid", "acct-b"), sidecar("ASSETS", "1", "groupUid", "1"),
      sidecar("ASSETS", "2", "uid", "acct-debit"), sidecar("ASSETS", "2", "groupUid", "3"),
      sidecar("ASSETS", "2", "cardAssetUid", "acct-b"),
      sidecar("ASSETGROUP", "1", "uid", "1"), sidecar("ASSETGROUP", "1", "TYPE", "1"),
      sidecar("ASSETGROUP", "3", "uid", "3"), sidecar("ASSETGROUP", "3", "TYPE", groupType),
    ])
  }

  static func replay(
    account: MoneyManagerV19Semantics.RetainedField, eventAccount: String,
    rowAccount: String = "acct-debit", accounts: MoneyManagerV19Semantics.RetainedAccounts?
  ) throws -> MoneyManagerV19Semantics.ReplayResult {
    let zone = try SourceTimeZone(fixedOffsetSeconds: 19_800)
    let temporal = try #require(
      MoneyManagerV19Semantics.temporal(zdateEpochMilliseconds: 1_738_547_700_000, in: zone))
    func field(_ semantic: CanonicalEventSourceSemantic, _ table: String, _ column: String, _ value: String)
      -> MoneyManagerV19Semantics.RetainedField
    {
      .init(
        semantic: semantic,
        locator: SourceLocator(table: table, recordKey: "9", columnName: column),
        storageClass: .text, payload: Data(value.utf8))
    }
    let fields = [
      field(.amount, "INOUTCOME", "ZMONEY", "7.00"), field(.currency, "CURRENCY", "ISO", "USD"),
      field(.occurredAt, "INOUTCOME", "ZDATE", "1738547700000"), account,
      field(.kind, "INOUTCOME", "DO_TYPE", "1"),
    ]
    let sidecars = [
      sidecar("INOUTCOME", "9", "assetUid", rowAccount),
      sidecar("INOUTCOME", "9", "WDATE", "2025-02-03"),
    ]
    let provenance = try FieldProvenance(
      artifactSHA256: String(repeating: "a", count: 64), profileID: profile,
      adapterVersion: MoneyManagerV19Semantics.adapterVersion,
      locator: SourceLocator(table: "INOUTCOME", recordKey: "9", columnName: "ZMONEY"),
      deterministicID: String(repeating: "b", count: 64))
    let event = try CanonicalEconomicEvent(
      eventID: String(repeating: "c", count: 64),
      accountID: StableCanonicalID.account(profileID: profile, sourceAccountID: eventAccount),
      kind: .expense, amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("7.00")),
      occurredAt: temporal, sourceRecordID: String(repeating: "d", count: 64),
      amountProvenance: provenance,
      sourceBindings: try zip(CanonicalEventSourceSemantic.allCases, ["b", "1", "2", "3", "4"]).map {
        semantic, digit in
        try CanonicalEventSourceBinding(
          semantic: semantic,
          provenance: semantic == .amount
            ? provenance
            : FieldProvenance(
              artifactSHA256: provenance.artifactSHA256, profileID: profile,
              adapterVersion: provenance.adapterVersion, locator: provenance.locator,
              deterministicID: String(repeating: digit, count: 64)),
          declaredType: nil, storageClass: .text)
      },
      sidecarReferences: [])
    return MoneyManagerV19Semantics.validateReplay(
      profileID: profile, adapterVersion: MoneyManagerV19Semantics.adapterVersion, event: event,
      fields: fields, sidecars: sidecars, accounts: accounts,
      temporalCommitment: MoneyManagerV19Semantics.temporalCommitment(temporal))
  }

  static let cardProof = MoneyManagerV19Semantics.RetainedField(
    semantic: .account,
    locator: SourceLocator(table: "ASSETS", recordKey: "2", columnName: "cardAssetUid"),
    storageClass: .text, payload: Data("acct-b".utf8))
  static let rowProof = MoneyManagerV19Semantics.RetainedField(
    semantic: .account,
    locator: SourceLocator(table: "INOUTCOME", recordKey: "9", columnName: "assetUid"),
    storageClass: .text, payload: Data("acct-debit".utf8))

  @Test("a debit card's entry proven by the card's paying account replays")
  func cardProofReplays() throws {
    #expect(try Self.replay(account: Self.cardProof, eventAccount: "acct-b", accounts: Self.accounts()) == .valid)
  }

  @Test("an entry imported before the fix, on the card itself, still replays")
  func legacyProofStillReplays() throws {
    #expect(try Self.replay(account: Self.rowProof, eventAccount: "acct-debit", accounts: nil) == .valid)
    #expect(
      try Self.replay(account: Self.rowProof, eventAccount: "acct-debit", accounts: Self.accounts())
        == .valid)
  }

  @Test("a card proof fails when the card is not a debit card, the row names another account, or the accounts are missing")
  func cardProofIsChecked() throws {
    #expect(
      try Self.replay(account: Self.cardProof, eventAccount: "acct-b", accounts: Self.accounts(groupType: "2"))
        == .invalid)
    #expect(
      try Self.replay(
        account: Self.cardProof, eventAccount: "acct-b", rowAccount: "acct-a", accounts: Self.accounts())
        == .invalid)
    #expect(try Self.replay(account: Self.cardProof, eventAccount: "acct-b", accounts: nil) == .invalid)
    // The event must sit on the paying account the proof names.
    #expect(
      try Self.replay(account: Self.cardProof, eventAccount: "acct-debit", accounts: Self.accounts())
        == .invalid)
    // A credit-card style proof column on a transaction row is not a card proof.
    let wrongColumn = MoneyManagerV19Semantics.RetainedField(
      semantic: .account,
      locator: SourceLocator(table: "ASSETS", recordKey: "2", columnName: "groupUid"),
      storageClass: .text, payload: Data("3".utf8))
    #expect(try Self.replay(account: wrongColumn, eventAccount: "acct-b", accounts: Self.accounts()) == .invalid)
  }
}

private struct ImportedDebitFixture {
  let snapshot: LedgerStore.LedgerReadSnapshot
  let receipt: ImportBalanceReceipt
  var effects: [LedgerTransactionEffect] {
    snapshot.transactions.filter { $0.currentRevision.lifecycle == .active }
      .flatMap(\.currentRevision.draft.effects)
  }
}

private func withImport(extraSQL: String, _ body: (ImportedDebitFixture) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("MM(synthetic).mmbak")
  try SyntheticV19Backup.write(to: source)
  var database: OpaquePointer?
  guard sqlite3_open_v2(source.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
    let database
  else { throw SyntheticV19BackupError.sqlite }
  let executed = sqlite3_exec(database, extraSQL, nil, nil, nil)
  sqlite3_close(database)
  guard executed == SQLITE_OK else { throw SyntheticV19BackupError.sqlite }

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
  // Opening runs the ledger's full health check, which replays every event's account proof.
  let store = try LedgerStore.openReadOnly(at: canonical)
  let snapshot = try store.readSnapshot()
  let receipt = try ImportBalanceReceipt.build(
    source: balances, accounts: snapshot.accounts, transactions: snapshot.transactions,
    importedAt: UTCInstant(epochMilliseconds: 1_762_000_000_000), importID: store.latestImportID())
  try body(ImportedDebitFixture(snapshot: snapshot, receipt: receipt))
}
