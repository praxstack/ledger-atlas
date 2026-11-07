import Foundation

/// The rows of a ledger view as a CSV file (#170).
///
/// One row per transaction, in the order given (the caller passes the view's matches, so the
/// file has the same rows and order as the screen). Amounts are the stored exact decimals with
/// no grouping and a plain minus for money leaving the row's account. The file is UTF-8 with a
/// byte-order mark and CRLF line ends, and fields are quoted per RFC 4180, so Numbers and Excel
/// open it as written. A text cell that a spreadsheet would read as a formula (it starts with
/// `=`, `+`, `-` or `@`, or with a tab or carriage return) gets a leading single quote.
public enum LedgerCSVExport {
  public static let header = [
    "date", "account", "kind", "category", "amount", "currency", "memo", "tags",
    "transfer_counterpart", "status", "id",
  ]

  /// Names used to spell out ids. A missing name falls back to the id itself.
  public struct Names: Sendable {
    public var accounts: [String: String]
    public var categories: [LedgerCategory]
    public var tags: [String: String]

    public init(
      accounts: [String: String] = [:], categories: [LedgerCategory] = [],
      tags: [String: String] = [:]
    ) {
      self.accounts = accounts
      self.categories = categories
      self.tags = tags
    }
  }

  /// The cells of each row, before quoting. `revisionTags` is keyed by revision id, as the
  /// ledger view reads it.
  public static func rows(
    _ transactions: [LedgerTransactionSnapshot], names: Names,
    revisionTags: [String: LedgerTagLinks] = [:]
  ) -> [[String]] {
    let categoriesByID = Dictionary(
      names.categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let parents = LedgerPeriodStatistics.acyclicParents(categoriesByID)
    func categoryPath(_ id: String?) -> String {
      guard let id else { return "" }
      guard let category = categoriesByID[id] else { return id }
      var path = [category.name]
      var cursor = parents[id]
      while let current = cursor, let parent = categoriesByID[current] {
        path.append(parent.name)
        cursor = parents[current]
      }
      return path.reversed().joined(separator: " > ")
    }
    func account(_ id: String) -> String { names.accounts[id] ?? id }

    return transactions.map { transaction in
      let revision = transaction.currentRevision
      let draft = revision.draft
      // A transfer's row belongs to the account the money leaves; every other kind has one
      // effect.
      let main = draft.effects.first { $0.direction == .decrease } ?? draft.effects[0]
      let counterpart =
        draft.kind == .transfer
        ? draft.effects.first { $0.accountID != main.accountID }.map { account($0.accountID) } ?? ""
        : ""
      let tags = (revisionTags[revision.id]?.tagIDs ?? []).map { names.tags[$0] ?? $0 }
      return [
        date(draft.occurredAt),
        account(main.accountID),
        draft.kind.rawValue,
        categoryPath(draft.categoryID),
        amount(main.amount.amount, leaving: main.direction == .decrease),
        main.amount.unitCode,
        draft.note ?? "",
        tags.joined(separator: "; "),
        counterpart,
        revision.lifecycle == .active ? "active" : "closed",
        transaction.id,
      ]
    }
  }

  /// The whole file: byte-order mark, header and rows.
  public static func data(
    _ transactions: [LedgerTransactionSnapshot], names: Names,
    revisionTags: [String: LedgerTagLinks] = [:]
  ) -> Data {
    data(rows: rows(transactions, names: names, revisionTags: revisionTags))
  }

  /// Quotes and joins rows. Every column but `amount` is text, so only those cells are guarded
  /// against formulas; an amount is written by `amount(_:leaving:)` and is always a number.
  public static func data(rows: [[String]]) -> Data {
    let amountColumn = header.firstIndex(of: "amount")!
    var text = line(header, amountColumn: nil)
    for row in rows { text += line(row, amountColumn: amountColumn) }
    return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
  }

  static func line(_ cells: [String], amountColumn: Int?) -> String {
    cells.enumerated().map { index, cell in
      field(index == amountColumn ? cell : neutralized(cell))
    }.joined(separator: ",") + "\r\n"
  }

  /// A spreadsheet runs a cell that starts with one of these as a formula.
  static func neutralized(_ cell: String) -> String {
    guard let first = cell.unicodeScalars.first,
      ["=", "+", "-", "@", "\t", "\r"].contains(first)
    else { return cell }
    return "'" + cell
  }

  /// RFC 4180: a field holding a comma, quote or line break is quoted, quotes doubled.
  static func field(_ cell: String) -> String {
    guard cell.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return cell }
    return "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

  /// The stored literal, signed: no grouping, no plus, a leading 0 before a bare point.
  static func amount(_ value: ExactDecimal, leaving: Bool) -> String {
    var literal = value.rawLiteral
    if literal.hasPrefix("+") || literal.hasPrefix("-") { literal.removeFirst() }
    if literal.hasPrefix(".") { literal = "0" + literal }
    if literal.hasSuffix(".") { literal.removeLast() }
    return leaving ? "-" + literal : literal
  }

  /// "2026-03-01" for a day, "2026-03-01 09:30" for a minute, then seconds and milliseconds
  /// as recorded.
  static func date(_ temporal: SourceTemporal) -> String {
    let local = temporal.localDateTime
    let day = String(format: "%04d-%02d-%02d", local.date.year, local.date.month, local.date.day)
    switch temporal.precision {
    case .day: return day
    case .minute: return day + String(format: " %02d:%02d", local.hour, local.minute)
    case .second:
      return day + String(format: " %02d:%02d:%02d", local.hour, local.minute, local.second)
    case .millisecond:
      return day
        + String(
          format: " %02d:%02d:%02d.%03d", local.hour, local.minute, local.second,
          local.millisecond)
    }
  }
}
