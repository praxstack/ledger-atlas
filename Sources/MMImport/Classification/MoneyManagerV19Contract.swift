import Foundation
import LedgerAdapterSemantics

/// The frozen Money Manager Android v19 contract
/// (docs/compatibility/money-manager-android-v19.schema.sql). Rule 2 of the contract: a v19
/// file missing any of these tables or columns is a different profile and is refused, never
/// guessed. Extra tables and columns are additive drift and stay admitted.
enum MoneyManagerV19Contract {
  static let androidTables: [String: [String]] = [
    "ASSETGROUP": ["DEVICE_ID", "uid", "IS_DEL", "USETIME", "ACC_GROUP_NAME", "TYPE", "ORDERSEQ", "isSynced", "syncTime", "syncVersion"],
    "ASSETS": ["ID", "CARD_DAY_FIN", "CARD_DAY_PAY", "NIC_NAME", "ORDERSEQ", "ZDATA", "ZDATA1", "ZDATA2", "IS_TRANS_EXPENSE", "IS_CARD_AUTO_PAY", "APP_PACKAGE", "APP_NAME", "SMS_TEL", "SMS_STRING", "A_UTIME", "CARD_USAGE_HURDLE_TYPE", "CARD_USAGE_HURDLE_START_DATE", "CARD_USAGE_HURDLE_AMOUNT", "uid", "currencyUid", "cardAssetUid", "groupUid", "isSynced", "syncTime", "syncVersion"],
    "BUDGET": ["ID", "uid", "targetUid", "DO_TYPE", "PERIOD_TYPE", "IS_TOTAL", "IS_DEL", "TRANSFER_TYPE", "ORDER_SEQ", "MODIFY_DATE", "isSynced", "syncTime", "syncVersion"],
    "BUDGET_AMOUNT": ["ID", "uid", "budgetUid", "IS_DEL", "AMOUNT", "BUDGET_PERIOD", "MODIFY_DATE", "isSynced", "syncTime", "syncVersion"],
    "CODE_DATA": ["id", "uid", "code", "data", "num", "isDel", "utime", "ctime", "isSynced", "syncTime", "syncVersion"],
    "CODE_LINK": ["id", "uid", "codeUid", "tableName", "tableUid", "orderSeq", "isDel", "utime", "ctime", "isSynced", "syncTime", "syncVersion"],
    "CURRENCY": ["ID", "uid", "NAME", "ISO", "MAIN_ISO", "IS_DEL", "ORDER_SEQ", "RATE", "SYMBOL", "INSERT_TYPE", "SYMBOL_POSITION", "IS_MAIN_CURRENCY", "IS_SHOW", "MODIFY_DATE", "DECIMAL_POINT", "isSynced", "syncTime", "syncVersion"],
    "FAVTRANSACTION": ["DEVICE_ID", "uid", "IS_DEL", "USETIME", "MARK", "DO_TYPE", "assetUid", "toAssetUid", "ctgUid", "AMOUNT_SUB", "currencyUid", "MEMO", "PAYEE", "ORDERSEQ", "isSynced", "syncTime", "syncVersion"],
    "INOUTCOME": ["AID", "uid", "assetUid", "CARDDIVIDMONTH", "ctgUid", "toAssetUid", "ZCONTENT", "ZDATE", "WDATE", "wtime", "paid", "DO_TYPE", "ZMONEY", "txUidTrans", "ZDATA", "SMS_RDATE", "IN_ZMONEY", "ASSET_NIC", "CATEGORY_NAME", "cardDivideUid", "CARD_DIVIDE_MONTH_STR", "MARK", "txUidFee", "SMS_ORIGIN", "SMS_PARSE_CONTENT", "IS_DEL", "UTIME", "currencyUid", "AMOUNT_ACCOUNT", "lat", "lng", "gstd", "isSynced", "syncTime", "syncVersion"],
    "MEMO": ["id", "uid", "title", "content", "memoTime", "memoDate", "pinned", "pinnedTime", "orderSeq", "color", "isDel", "utime", "isSynced", "syncTime", "syncVersion"],
    "MESSAGEMACRO2": ["AID", "uid", "conAssetUid", "MACROASSETNAME", "MACROTYPE", "SMS_TEL", "MODIDATE", "USEYN", "APP_PACKAGE", "APP_NAME", "ORDERSEQ", "utime", "isSynced", "syncTime", "syncVersion"],
    "PHOTO": ["DEVICE_ID", "uid", "IS_DEL", "USETIME", "txUid", "FILE_SIZE", "FILE_PATH", "FILE_NAME", "ORG_FILE_NAME", "ORG_FILE_PATH", "isSynced", "syncTime", "syncVersion"],
    "REPEATTRANSACTION": ["DEVICE_ID", "uid", "IS_DEL", "USETIME", "MARK", "END_DATE", "NEXT_DATE", "DO_TYPE", "REPEAT_TYPE", "assetUid", "toAssetUid", "ctgUid", "currencyUid", "AMOUNT_SUB", "MEMO", "PAYEE", "isSynced", "syncTime", "syncVersion"],
    "SMS_RAW_READ": ["ID", "uid", "RDATE", "ZDATE", "TEL", "ZDATA", "MACROTYPE", "assetUid", "toAssetUid", "NOTIFY_TYPE", "AMOUNT", "TEXT_PARSING_TIME", "ASSETNAME", "TYPE", "MMSID", "APP_PACKAGE", "APP_NAME", "SENDER_NAME", "IS_DEL", "utime", "isSynced", "syncTime", "syncVersion"],
    "TAG": ["id", "uid", "name", "orderSeq", "isDel", "utime", "isSynced", "syncTime", "syncVersion"],
    "TX_TAG": ["id", "uid", "txUid", "tagUid", "objName", "orderSeq", "isDel", "utime", "isSynced", "syncTime", "syncVersion"],
    "ZCATEGORY": ["ID", "C_IS_DEL", "C_UTIME", "uid", "NAME", "ORDERSEQ", "TYPE", "STATUS", "pUid", "isSynced", "syncTime", "syncVersion"],
    "ZETC": ["Z_PK", "uid", "E_UTIME", "ZDATATYPE", "ZDATA", "ZZDATA", "ZZDATA1", "ZZDATA2", "dataTypeKey", "isDel", "isSynced", "syncTime", "syncVersion"],
    "android_metadata": ["locale"],
  ]

  /// Columns every v19 family (Android, iOS, Mac) needs for the adapter to bind an event or
  /// its account, category and currency. Each inner list is one column under its aliases.
  static let coreColumns: [(tables: [String], columns: [[String]])] = [
    (
      ["INOUTCOME", "ZINOUTCOME"],
      [
        MoneyManagerV19Semantics.uidAliases, MoneyManagerV19Semantics.amountAliases,
        MoneyManagerV19Semantics.zdateAliases, MoneyManagerV19Semantics.assetAliases,
        MoneyManagerV19Semantics.doTypeAliases, MoneyManagerV19Semantics.categoryAliases,
      ]
    ),
    (["ASSETS", "ZASSETS"], [MoneyManagerV19Semantics.uidAliases]),
    (["ZCATEGORY", "CATEGORY"], [MoneyManagerV19Semantics.uidAliases]),
    (
      ["CURRENCY", "ZCURRENCY"],
      [MoneyManagerV19Semantics.uidAliases, MoneyManagerV19Semantics.isoAliases]
    ),
  ]

  /// True when `columnsByTable` (lower-cased column names, keyed by exact table name) has
  /// everything the contract needs for this family.
  static func isSatisfied(android: Bool, columnsByTable: [String: Set<String>]) -> Bool {
    if android {
      for (table, columns) in androidTables {
        guard let present = columnsByTable[table] else { return false }
        for column in columns where !present.contains(column.lowercased()) { return false }
      }
      return true
    }
    for requirement in coreColumns {
      guard let table = requirement.tables.first(where: { columnsByTable[$0] != nil }),
        let present = columnsByTable[table]
      else { return false }
      for aliases in requirement.columns
      where !aliases.contains(where: { present.contains($0.lowercased()) }) {
        return false
      }
    }
    return true
  }
}
