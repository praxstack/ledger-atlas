import CSQLite
import Foundation

/// A synthetic Money Manager v19 backup built from the frozen DDL
/// (docs/compatibility/money-manager-android-v19.schema.sql). No real data.
enum SyntheticV19Backup {
  /// `includingTransfers: false` leaves out every transfer leg, for ledgers that must also be
  /// valid at schema v11, which has no transfer pairs.
  /// `marker` adds one preserved settings row, which gives the backup (and so its import
  /// receipt) an identity no other test shares.
  static func write(to url: URL, includingTransfers: Bool = true, marker: String? = nil) throws {
    let ddlURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("docs/compatibility/money-manager-android-v19.schema.sql")
    let ddl = try String(contentsOf: ddlURL, encoding: .utf8)
    try execute(url, ddl)
    try execute(
      url, """
        INSERT INTO android_metadata (locale) VALUES ('en_US');
        INSERT INTO ASSETGROUP (uid, IS_DEL, ACC_GROUP_NAME, TYPE, ORDERSEQ)
          VALUES ('1', 0, 'Accounts', 1, 1);
        INSERT INTO CURRENCY (uid, NAME, ISO, MAIN_ISO, IS_DEL, RATE, IS_MAIN_CURRENCY, DECIMAL_POINT)
          VALUES ('cur-main', 'Synthetic', 'USD', 'USD', 0, 1.0, 1, 2);
        INSERT INTO ASSETS (uid, NIC_NAME, ZDATA, groupUid, currencyUid, ORDERSEQ)
          VALUES ('acct-a', 'Wallet', '0', '1', 'cur-main', 1),
                 ('acct-b', 'Bank', '0', '1', 'cur-main', 2);
        INSERT INTO ZCATEGORY (uid, NAME, TYPE, STATUS, pUid, C_IS_DEL)
          VALUES ('cat-salary', 'Salary', 0, 0, '0', 0),
                 ('cat-food', 'Food', 1, 0, '0', 0),
                 ('cat-snacks', 'Snacks', 1, 2, 'cat-food', 0);
        INSERT INTO INOUTCOME
          (uid, assetUid, ctgUid, toAssetUid, txUidTrans, DO_TYPE, ZMONEY, IN_ZMONEY,
           AMOUNT_ACCOUNT, ZDATE, WDATE, ZCONTENT, ZDATA, CARDDIVIDMONTH, currencyUid, UTIME)
        VALUES
          ('tx-income', 'acct-b', 'cat-salary', NULL, NULL, '0', '100.00', '100.00', 100.0,
           '1738547200000', '2025-02-03', 'synthetic', '', '0', 'cur-main', 1738547200000),
          ('tx-expense', 'acct-a', 'cat-snacks', NULL, NULL, '1', '12.50', '12.50', 12.5,
           '1738547260000', '2025-02-03', 'synthetic', '', '0', 'cur-main', 1738547260000),
          ('tx-balance-up', 'acct-a', '-4', NULL, NULL, '0', '3.00', '3.00', 3.0,
           '1738547320000', '2025-02-03', 'Difference', '', '0', 'cur-main', 1738547320000),
          ('tx-balance-down', 'acct-b', '-4', NULL, NULL, '1', '2.00', '2.00', 2.0,
           '1738547380000', '2025-02-03', 'Difference', '', '0', 'cur-main', 1738547380000),
          ('tx-balance-up-quiet', 'acct-b', '-4', NULL, NULL, '7', '4.00', '4.00', 4.0,
           '1738547390000', '2025-02-03', 'Difference', '', '0', 'cur-main', 1738547390000),
          ('tx-balance-down-quiet', 'acct-a', '-4', NULL, NULL, '8', '1.00', '1.00', 1.0,
           '1738547395000', '2025-02-03', 'Difference', '', '0', 'cur-main', 1738547395000),
          ('tx-transfer-out', 'acct-a', NULL, 'acct-b', 'grp-1', '3', '40.00', '40.00', 40.0,
           '1738547440000', '2025-02-03', '', '', '0', 'cur-main', 1738547440000),
          ('tx-transfer-in', 'acct-b', NULL, 'acct-a', 'grp-1', '4', '40.00', '40.00', 40.0,
           '1738547440000', '2025-02-03', '', '', '0', 'cur-main', 1738547440000),
          ('tx-orphan-out', 'acct-a', NULL, 'acct-b', 'grp-2', '3', '5.00', '5.00', 5.0,
           '1738547500000', '2025-02-03', '', '', '0', 'cur-main', 1738547500000),
          ('tx-self-out', 'acct-a', '', 'acct-a', 'grp-3', '3', '6.00', '6.00', 6.0,
           '1738547560000', '2025-02-03', '', '', '0', 'cur-main', 1738547560000),
          ('tx-self-in', 'acct-a', '', 'acct-a', 'grp-3', '4', '6.00', '6.00', 6.0,
           '1738547560001', '2025-02-03', '', '', '0', 'cur-main', 1738547560001);
        INSERT INTO PHOTO (uid, IS_DEL, txUid, FILE_SIZE, FILE_PATH, FILE_NAME)
          VALUES ('photo-1', 0, 'tx-expense', 10, '/synthetic/photo.jpg', 'photo.jpg');
        INSERT INTO REPEATTRANSACTION (uid, IS_DEL, END_DATE, NEXT_DATE, DO_TYPE, REPEAT_TYPE,
          assetUid, ctgUid, currencyUid, AMOUNT_SUB, MEMO, PAYEE)
          VALUES ('rule-1', 0, 0, 1741000000000, 1, 1, 'acct-a', 'cat-food', 'cur-main', 9.99, '',
            'synthetic'),
            ('rule-weekend', 0, 0, 1741000000000, 1, 10, 'acct-a', 'cat-food', 'cur-main', 5.0, '',
            'synthetic'),
            ('rule-inexact', 0, 0, 1741000000000, 1, 5, 'acct-a', 'cat-food', 'cur-main', 1.005, '',
            'synthetic');
        INSERT INTO TAG (uid, name, isDel) VALUES ('tag-1', 'synthetic', 0);
        INSERT INTO ZETC (uid, ZDATATYPE, ZDATA) VALUES ('etc-1', 100, 'en');
        INSERT INTO BUDGET (uid, targetUid, DO_TYPE, PERIOD_TYPE, IS_DEL)
          VALUES ('budget-1', 'cat-food', 1, 6, 0);
        INSERT INTO BUDGET_AMOUNT (uid, budgetUid, IS_DEL, AMOUNT) VALUES ('ba-1', 'budget-1', 0, 50.0);
        """)
    if !includingTransfers { try dropTransfers(url) }
    if let marker {
      try execute(
        url, "INSERT INTO ZETC (uid, ZDATATYPE, ZDATA) VALUES ('etc-marker', 100, '\(marker)')")
    }
  }

  private static func dropTransfers(_ url: URL) throws {
    try execute(url, "DELETE FROM INOUTCOME WHERE DO_TYPE IN ('3', '4')")
  }

  private static func execute(_ url: URL, _ sql: String) throws {
    var database: OpaquePointer?
    guard
      sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        == SQLITE_OK,
      let database
    else { throw SyntheticV19BackupError.sqlite }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
      throw SyntheticV19BackupError.sqlite
    }
  }
}

enum SyntheticV19BackupError: Error { case sqlite }
