import Foundation

/// The ledger as an XLSX workbook, and back.
///
/// The workbook is a versioned projection, never canonical truth. Export writes one sheet per
/// record type with stable ids, so an exported file re-imports to the same records. Import
/// validates everything before handing anything back and reports every problem by sheet, row
/// and column, so a preview can show them all at once. Applying the result to a ledger
/// (and skipping records it already has) is the caller's job.
public enum LedgerXLSXExchange {
  public static let format = "ledger-atlas-xlsx"
  public static let version = 1

  /// What a workbook carries.
  public struct Content: Equatable, Sendable {
    public var accountGroups: [LedgerAccountGroup]
    public var accounts: [LedgerAccount]
    public var categories: [LedgerCategory]
    public var tags: [LedgerTag]
    public var transactions: [Transaction]

    public init(
      accountGroups: [LedgerAccountGroup] = [], accounts: [LedgerAccount] = [],
      categories: [LedgerCategory] = [], tags: [LedgerTag] = [], transactions: [Transaction] = []
    ) {
      self.accountGroups = accountGroups
      self.accounts = accounts
      self.categories = categories
      self.tags = tags
      self.transactions = transactions
    }
  }

  /// A transaction as it currently reads: its latest draft, lifecycle and tags.
  public struct Transaction: Equatable, Sendable {
    public var id: String
    public var draft: LedgerTransactionDraft
    public var lifecycle: LedgerLifecycleState
    public var tags: LedgerTagLinks

    public init(
      id: String, draft: LedgerTransactionDraft, lifecycle: LedgerLifecycleState = .active,
      tags: LedgerTagLinks = try! LedgerTagLinks()
    ) {
      self.id = id
      self.draft = draft
      self.lifecycle = lifecycle
      self.tags = tags
    }
  }

  /// One problem in an imported workbook. Rows are spreadsheet row numbers (header = 1).
  public struct Issue: Equatable, Sendable, CustomStringConvertible {
    public let sheet: String
    public let row: Int?
    public let column: String?
    public let message: String

    public init(sheet: String, row: Int? = nil, column: String? = nil, message: String) {
      self.sheet = sheet
      self.row = row
      self.column = column
      self.message = message
    }

    public var description: String {
      var place = sheet
      if let row { place += " row \(row)" }
      if let column { place += ", \(column)" }
      return "\(place): \(message)"
    }
  }

  public enum Error: Swift.Error, Equatable, Sendable {
    /// The workbook was read but its content is not valid. At most `maximumIssues` are listed.
    case invalid([Issue])
  }

  public static let maximumIssues = 200

  enum Sheet {
    static let about = "About"
    static let accountGroups = "Account groups"
    static let accounts = "Accounts"
    static let categories = "Categories"
    static let tags = "Tags"
    static let transactions = "Transactions"
    static let effects = "Effects"
    static let sourceLiterals = "Source literals"
  }

  static let originColumns = ["origin_id", "origin_label", "origin_provenance_id"]
  static let columns: [String: [String]] = [
    Sheet.accountGroups: ["id", "name", "display_order", "lifecycle"],
    Sheet.accounts: [
      "id", "name", "currency", "variant", "group_id", "display_order", "hidden",
      "include_in_totals", "lifecycle",
    ] + originColumns,
    Sheet.categories: [
      "id", "name", "kind", "parent_id", "display_order", "hidden", "lifecycle",
    ] + originColumns,
    Sheet.tags: ["id", "name", "lifecycle"] + originColumns,
    Sheet.transactions: [
      "id", "kind", "local_date_time", "time_zone", "utc_offset_seconds", "precision",
      "instant_ms", "category_id", "note", "rounding_policy", "tag_ids", "lifecycle",
    ] + originColumns,
    Sheet.effects: ["transaction_id", "account_id", "direction", "amount", "currency"],
    Sheet.sourceLiterals: ["transaction_id", "field", "literal", "provenance_id"],
  ]
  static let sheetOrder = [
    Sheet.accountGroups, Sheet.accounts, Sheet.categories, Sheet.tags, Sheet.transactions,
    Sheet.effects, Sheet.sourceLiterals,
  ]
}

// MARK: - Export

extension LedgerXLSXExchange {
  public static func workbook(_ content: Content) -> XLSXWorkbook {
    let about = XLSXWorkbook.Sheet(
      name: Sheet.about,
      rows: [
        ["key", "value"], ["format", format], ["version", String(version)],
        [
          "note",
          "A Ledger Atlas export. Each sheet lists one kind of record by id. Edit values, not ids or headers; formulas and merged cells are refused on import.",
        ],
      ])
    func sheet(_ name: String, _ rows: [[String]]) -> XLSXWorkbook.Sheet {
      XLSXWorkbook.Sheet(name: name, rows: [columns[name]!] + rows)
    }
    func origin(_ origin: LedgerOrigin) -> [String] {
      [origin.id, origin.label, origin.provenanceID ?? ""]
    }

    let groups = content.accountGroups.sorted { $0.id < $1.id }.map {
      [$0.id, $0.name, String($0.displayOrder), $0.lifecycle.rawValue]
    }
    let accounts = content.accounts.sorted { $0.id < $1.id }.map {
      [
        $0.id, $0.name, $0.currencyUnit, $0.variant.rawValue, $0.groupID ?? "",
        String($0.displayOrder), flag($0.hidden), flag($0.includeInTotals), $0.lifecycle.rawValue,
      ] + origin($0.origin)
    }
    let categories = content.categories.sorted { $0.id < $1.id }.map {
      [
        $0.id, $0.name, $0.kind.rawValue, $0.parentID ?? "", String($0.displayOrder),
        flag($0.hidden), $0.lifecycle.rawValue,
      ] + origin($0.origin)
    }
    let tags = content.tags.sorted { $0.id < $1.id }.map {
      [$0.id, $0.name, $0.lifecycle.rawValue] + origin($0.origin)
    }
    var transactions: [[String]] = []
    var effects: [[String]] = []
    var literals: [[String]] = []
    for transaction in content.transactions.sorted(by: { $0.id < $1.id }) {
      let draft = transaction.draft
      let when = draft.occurredAt
      transactions.append(
        [
          transaction.id, draft.kind.rawValue, localDateTime(when.localDateTime),
          when.timeZone.ianaIdentifier ?? "", String(when.resolvedOffsetSeconds),
          when.precision.rawValue, String(when.instant.epochMilliseconds), draft.categoryID ?? "",
          draft.note ?? "", draft.roundingPolicy?.rawValue ?? "",
          transaction.tags.tagIDs.joined(separator: " "), transaction.lifecycle.rawValue,
        ] + origin(draft.origin))
      for effect in draft.effects {
        effects.append([
          transaction.id, effect.accountID, effect.direction.rawValue,
          effect.amount.amount.rawLiteral, effect.amount.unitCode,
        ])
      }
      for literal in draft.sourceLiterals {
        literals.append([transaction.id, literal.field, literal.literal, literal.provenanceID ?? ""])
      }
    }
    return XLSXWorkbook(sheets: [
      about,
      sheet(Sheet.accountGroups, groups),
      sheet(Sheet.accounts, accounts),
      sheet(Sheet.categories, categories),
      sheet(Sheet.tags, tags),
      sheet(Sheet.transactions, transactions),
      sheet(Sheet.effects, effects),
      sheet(Sheet.sourceLiterals, literals),
    ])
  }

  public static func xlsxData(_ content: Content) throws -> Data {
    try workbook(content).xlsxData()
  }

  static func flag(_ value: Bool) -> String { value ? "TRUE" : "FALSE" }

  /// "2026-03-01 09:30:00.000": always every component, so the text sorts and reads the same.
  static func localDateTime(_ value: SourceLocalDateTime) -> String {
    String(
      format: "%04d-%02d-%02d %02d:%02d:%02d.%03d", value.date.year, value.date.month,
      value.date.day, value.hour, value.minute, value.second, value.millisecond)
  }
}

// MARK: - Import

extension LedgerXLSXExchange {
  public static func content(fromXLSX data: Data) throws -> Content {
    try content(from: XLSXWorkbook(xlsxData: data))
  }

  public static func content(from workbook: XLSXWorkbook) throws -> Content {
    var reader = Reader()
    let content = reader.read(workbook)
    guard reader.issues.isEmpty, let content else {
      throw Error.invalid(Array(reader.issues.prefix(maximumIssues)))
    }
    return content
  }

  /// A table: header names mapped to columns, with each record's spreadsheet row number.
  struct Table {
    let sheet: String
    let columns: [String: Int]
    let rows: [(number: Int, cells: [String])]

    func value(_ row: [String], _ column: String) -> String {
      guard let index = columns[column], index < row.count else { return "" }
      return row[index]
    }
  }

  struct Reader {
    var issues: [Issue] = []

    mutating func report(_ sheet: String, _ row: Int?, _ column: String?, _ message: String) {
      if issues.count <= LedgerXLSXExchange.maximumIssues {
        issues.append(Issue(sheet: sheet, row: row, column: column, message: message))
      }
    }

    mutating func read(_ workbook: XLSXWorkbook) -> Content? {
      guard checkAbout(workbook) else { return nil }
      let known = Set([Sheet.about] + sheetOrder)
      for sheet in workbook.sheets where !known.contains(sheet.name) {
        report(sheet.name, nil, nil, "This sheet is not part of a Ledger Atlas export.")
      }
      var tables: [String: Table] = [:]
      for name in sheetOrder {
        guard let sheet = workbook.sheet(named: name) else {
          report(name, nil, nil, "The sheet is missing.")
          continue
        }
        if let table = self.table(sheet) { tables[name] = table }
      }
      guard tables.count == sheetOrder.count else { return nil }

      let groups = readGroups(tables[Sheet.accountGroups]!)
      let accounts = readAccounts(tables[Sheet.accounts]!, groups: Set(groups.map(\.id)))
      let categories = readCategories(tables[Sheet.categories]!)
      let tags = readTags(tables[Sheet.tags]!)
      let transactions = readTransactions(
        tables[Sheet.transactions]!, effects: tables[Sheet.effects]!,
        literals: tables[Sheet.sourceLiterals]!,
        accounts: Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
        categories: Dictionary(
          categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
        tags: Set(tags.map(\.id)))
      return Content(
        accountGroups: groups, accounts: accounts, categories: categories, tags: tags,
        transactions: transactions)
    }

    mutating func checkAbout(_ workbook: XLSXWorkbook) -> Bool {
      guard let about = workbook.sheet(named: Sheet.about) else {
        report(Sheet.about, nil, nil, "This is not a Ledger Atlas export: the About sheet is missing.")
        return false
      }
      var values: [String: String] = [:]
      for row in about.rows.dropFirst() where row.count >= 2 { values[row[0]] = row[1] }
      guard values["format"] == LedgerXLSXExchange.format else {
        report(Sheet.about, nil, nil, "This is not a Ledger Atlas export.")
        return false
      }
      guard values["version"] == String(LedgerXLSXExchange.version) else {
        report(
          Sheet.about, nil, nil,
          "Export version \(values["version"] ?? "unknown") is not supported; this app reads version \(LedgerXLSXExchange.version).")
        return false
      }
      return true
    }

    /// Checks the header row exactly: every expected column once, nothing extra.
    mutating func table(_ sheet: XLSXWorkbook.Sheet) -> Table? {
      let expected = LedgerXLSXExchange.columns[sheet.name]!
      let header = sheet.rows.first ?? []
      var columns: [String: Int] = [:]
      var ok = true
      for (index, name) in header.enumerated() where !name.isEmpty {
        if !expected.contains(name) {
          report(sheet.name, 1, name, "Unknown column.")
          ok = false
        } else if columns[name] != nil {
          report(sheet.name, 1, name, "The column appears twice.")
          ok = false
        } else {
          columns[name] = index
        }
      }
      for name in expected where columns[name] == nil {
        report(sheet.name, 1, name, "The column is missing.")
        ok = false
      }
      guard ok else { return nil }
      let rows = sheet.rows.enumerated().dropFirst().compactMap { index, cells in
        cells.allSatisfy(\.isEmpty) ? nil : (number: index + 1, cells: cells)
      }
      return Table(sheet: sheet.name, columns: columns, rows: rows)
    }

    // MARK: Field parsers. Each reports its own problem and returns nil.

    mutating func required(_ table: Table, _ row: (number: Int, cells: [String]), _ column: String)
      -> String?
    {
      let value = table.value(row.cells, column)
      if value.isEmpty { report(table.sheet, row.number, column, "A value is required.") }
      return value.isEmpty ? nil : value
    }

    mutating func optional(_ table: Table, _ row: (number: Int, cells: [String]), _ column: String)
      -> String?
    {
      let value = table.value(row.cells, column)
      return value.isEmpty ? nil : value
    }

    mutating func choice<T: RawRepresentable>(
      _ table: Table, _ row: (number: Int, cells: [String]), _ column: String, _: T.Type
    ) -> T? where T.RawValue == String, T: CaseIterable {
      guard let text = required(table, row, column) else { return nil }
      guard let value = T(rawValue: text) else {
        let allowed = T.allCases.map(\.rawValue).joined(separator: ", ")
        report(table.sheet, row.number, column, "“\(text)” is not one of: \(allowed).")
        return nil
      }
      return value
    }

    mutating func integer(
      _ table: Table, _ row: (number: Int, cells: [String]), _ column: String,
      minimum: Int = 0
    ) -> Int? {
      guard let text = required(table, row, column) else { return nil }
      guard let value = Int(text), value >= minimum else {
        report(table.sheet, row.number, column, "“\(text)” is not a whole number of at least \(minimum).")
        return nil
      }
      return value
    }

    mutating func boolean(_ table: Table, _ row: (number: Int, cells: [String]), _ column: String)
      -> Bool?
    {
      guard let text = required(table, row, column) else { return nil }
      switch text.uppercased() {
      case "TRUE", "1", "YES": return true
      case "FALSE", "0", "NO": return false
      default:
        report(table.sheet, row.number, column, "“\(text)” is not TRUE or FALSE.")
        return nil
      }
    }

    mutating func origin(_ table: Table, _ row: (number: Int, cells: [String])) -> LedgerOrigin? {
      guard let id = required(table, row, "origin_id"), let label = required(table, row, "origin_label")
      else { return nil }
      do {
        return try LedgerOrigin(
          id: id, label: label, provenanceID: optional(table, row, "origin_provenance_id"))
      } catch {
        report(table.sheet, row.number, "origin_id", "The origin is not valid.")
        return nil
      }
    }

    mutating func uniqueIDs<T>(_ table: Table, _ records: [(row: Int, id: String, value: T)]) -> [T] {
      var seen: Set<String> = []
      var kept: [T] = []
      for record in records {
        if seen.insert(record.id).inserted {
          kept.append(record.value)
        } else {
          report(table.sheet, record.row, "id", "This id is already used on an earlier row.")
        }
      }
      return kept
    }

    // MARK: Sheets

    mutating func readGroups(_ table: Table) -> [LedgerAccountGroup] {
      var records: [(row: Int, id: String, value: LedgerAccountGroup)] = []
      for row in table.rows {
        let id = required(table, row, "id")
        let name = required(table, row, "name")
        let order = integer(table, row, "display_order")
        let lifecycle = choice(table, row, "lifecycle", LedgerLifecycleState.self)
        guard let id, let name, let order, let lifecycle else { continue }
        do {
          records.append(
            (row.number, id, try LedgerAccountGroup(id: id, name: name, displayOrder: order, lifecycle: lifecycle)))
        } catch {
          report(table.sheet, row.number, nil, "The account group is not valid (check the id and name).")
        }
      }
      return uniqueIDs(table, records)
    }

    mutating func readAccounts(_ table: Table, groups: Set<String>) -> [LedgerAccount] {
      var records: [(row: Int, id: String, value: LedgerAccount)] = []
      for row in table.rows {
        let id = required(table, row, "id")
        let name = required(table, row, "name")
        let currency = required(table, row, "currency")
        let variant = choice(table, row, "variant", LedgerAccountVariant.self)
        let groupID = optional(table, row, "group_id")
        let order = integer(table, row, "display_order")
        let hidden = boolean(table, row, "hidden")
        let included = boolean(table, row, "include_in_totals")
        let lifecycle = choice(table, row, "lifecycle", LedgerLifecycleState.self)
        let origin = origin(table, row)
        if let groupID, !groups.contains(groupID) {
          report(table.sheet, row.number, "group_id", "No account group has this id.")
          continue
        }
        guard let id, let name, let currency, let variant, let order, let hidden, let included,
          let lifecycle, let origin
        else { continue }
        do {
          records.append(
            (
              row.number, id,
              try LedgerAccount(
                id: id, name: name, currencyUnit: currency, origin: origin, lifecycle: lifecycle,
                groupID: groupID, displayOrder: order, hidden: hidden, includeInTotals: included,
                variant: variant)
            ))
        } catch {
          report(table.sheet, row.number, nil, "The account is not valid (check the id, name and currency).")
        }
      }
      return uniqueIDs(table, records)
    }

    mutating func readCategories(_ table: Table) -> [LedgerCategory] {
      var records: [(row: Int, id: String, value: LedgerCategory)] = []
      for row in table.rows {
        let id = required(table, row, "id")
        let name = required(table, row, "name")
        let kind = choice(table, row, "kind", LedgerCategoryKind.self)
        let parentID = optional(table, row, "parent_id")
        let order = integer(table, row, "display_order")
        let hidden = boolean(table, row, "hidden")
        let lifecycle = choice(table, row, "lifecycle", LedgerLifecycleState.self)
        let origin = origin(table, row)
        guard let id, let name, let kind, let order, let hidden, let lifecycle, let origin else {
          continue
        }
        do {
          records.append(
            (
              row.number, id,
              try LedgerCategory(
                id: id, name: name, kind: kind, origin: origin, lifecycle: lifecycle,
                parentID: parentID, displayOrder: order, hidden: hidden)
            ))
        } catch {
          report(table.sheet, row.number, nil, "The category is not valid (check the id, name and parent).")
        }
      }
      let categories = uniqueIDs(table, records)
      // Parents must exist, share the kind, and not loop.
      let byID = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      let rowOf = Dictionary(records.map { ($0.id, $0.row) }, uniquingKeysWith: { first, _ in first })
      for category in categories {
        guard let parentID = category.parentID else { continue }
        let row = rowOf[category.id]
        guard let parent = byID[parentID] else {
          report(table.sheet, row, "parent_id", "No category has this id.")
          continue
        }
        if parent.kind != category.kind {
          report(table.sheet, row, "parent_id", "The parent is a \(parent.kind.rawValue) category.")
        }
        var seen: Set<String> = [category.id]
        var cursor = parent.parentID
        while let next = cursor {
          guard seen.insert(next).inserted else {
            report(table.sheet, row, "parent_id", "The parents form a loop.")
            break
          }
          cursor = byID[next]?.parentID
        }
      }
      return categories
    }

    mutating func readTags(_ table: Table) -> [LedgerTag] {
      var records: [(row: Int, id: String, value: LedgerTag)] = []
      for row in table.rows {
        let id = required(table, row, "id")
        let name = required(table, row, "name")
        let lifecycle = choice(table, row, "lifecycle", LedgerLifecycleState.self)
        let origin = origin(table, row)
        guard let id, let name, let lifecycle, let origin else { continue }
        do {
          records.append(
            (row.number, id, try LedgerTag(id: id, name: name, origin: origin, lifecycle: lifecycle)))
        } catch {
          report(table.sheet, row.number, nil, "The tag is not valid (check the id and name).")
        }
      }
      return uniqueIDs(table, records)
    }

    mutating func readTransactions(
      _ table: Table, effects effectTable: Table, literals literalTable: Table,
      accounts: [String: LedgerAccount], categories: [String: LedgerCategory], tags: Set<String>
    ) -> [Transaction] {
      var effects: [String: [(row: Int, effect: LedgerTransactionEffect)]] = [:]
      for row in effectTable.rows {
        let transactionID = required(effectTable, row, "transaction_id")
        let accountID = required(effectTable, row, "account_id")
        let direction = choice(effectTable, row, "direction", LedgerEffectDirection.self)
        let amountText = required(effectTable, row, "amount")
        let currency = required(effectTable, row, "currency")
        guard let transactionID, let accountID, let direction, let amountText, let currency else {
          continue
        }
        guard let account = accounts[accountID] else {
          report(effectTable.sheet, row.number, "account_id", "No account has this id.")
          continue
        }
        guard currency == account.currencyUnit else {
          report(
            effectTable.sheet, row.number, "currency",
            "The account “\(account.name)” holds \(account.currencyUnit), not \(currency).")
          continue
        }
        guard let amount = try? ExactDecimal(amountText),
          let value = try? CurrencyAmount(unitCode: currency, amount: amount),
          let effect = try? LedgerTransactionEffect(
            accountID: accountID, direction: direction, amount: value)
        else {
          report(effectTable.sheet, row.number, "amount", "“\(amountText)” is not a valid amount.")
          continue
        }
        effects[transactionID, default: []].append((row.number, effect))
      }

      var literals: [String: [LedgerSourceLiteral]] = [:]
      for row in literalTable.rows {
        let transactionID = required(literalTable, row, "transaction_id")
        let field = required(literalTable, row, "field")
        let literal = literalTable.value(row.cells, "literal")
        guard let transactionID, let field else { continue }
        do {
          literals[transactionID, default: []].append(
            try LedgerSourceLiteral(
              field: field, literal: literal,
              provenanceID: optional(literalTable, row, "provenance_id")))
        } catch {
          report(literalTable.sheet, row.number, nil, "The source literal is not valid.")
        }
      }

      var records: [(row: Int, id: String, value: Transaction)] = []
      var transactionIDs: Set<String> = []
      for row in table.rows {
        let id = required(table, row, "id")
        if let id { transactionIDs.insert(id) }
        let kind = choice(table, row, "kind", LedgerTransactionKind.self)
        let when = temporal(table, row)
        let categoryID = optional(table, row, "category_id")
        let note = optional(table, row, "note")
        let rounding: RoundingPolicy? =
          optional(table, row, "rounding_policy") == nil
          ? nil : choice(table, row, "rounding_policy", RoundingPolicy.self)
        let roundingFailed = optional(table, row, "rounding_policy") != nil && rounding == nil
        let lifecycle = choice(table, row, "lifecycle", LedgerLifecycleState.self)
        let origin = origin(table, row)
        var tagLinks: LedgerTagLinks?
        let tagIDs = table.value(row.cells, "tag_ids").split(whereSeparator: \.isWhitespace)
          .map(String.init)
        if let unknown = tagIDs.first(where: { !tags.contains($0) }) {
          report(table.sheet, row.number, "tag_ids", "No tag has the id \(unknown).")
        } else if let links = try? LedgerTagLinks(tagIDs) {
          tagLinks = links
        } else {
          report(table.sheet, row.number, "tag_ids", "Tag ids must be distinct, at most 64.")
        }
        if let categoryID, categories[categoryID] == nil {
          report(table.sheet, row.number, "category_id", "No category has this id.")
          continue
        }
        guard let id, let kind, let when, let lifecycle, let origin, let tagLinks, !roundingFailed
        else { continue }
        let legs = effects[id] ?? []
        guard !legs.isEmpty else {
          report(table.sheet, row.number, "id", "The Effects sheet has no rows for this transaction.")
          continue
        }
        if let categoryID, let category = categories[categoryID],
          let expected = categoryKind(for: kind), category.kind != expected
        {
          report(
            table.sheet, row.number, "category_id",
            "A \(kind.rawValue) cannot use the \(category.kind.rawValue) category “\(category.name)”.")
          continue
        }
        do {
          let draft = try LedgerTransactionDraft(
            effects: legs.map(\.effect), categoryID: categoryID, kind: kind, occurredAt: when,
            note: note, roundingPolicy: rounding, sourceLiterals: literals[id] ?? [], origin: origin)
          records.append(
            (row.number, id, Transaction(id: id, draft: draft, lifecycle: lifecycle, tags: tagLinks)))
        } catch {
          report(
            table.sheet, row.number, nil,
            "The \(kind.rawValue) does not add up: check its Effects rows (directions, one row per account) and category.")
        }
      }
      for (sheet, ids) in [
        (effectTable, effects.keys.map { $0 }), (literalTable, literals.keys.map { $0 }),
      ] {
        for id in ids.sorted() where !transactionIDs.contains(id) {
          report(sheet.sheet, nil, "transaction_id", "No transaction has the id \(id).")
        }
      }
      return uniqueIDs(table, records)
    }

    /// The category kind a transaction kind may use, or nil when any is allowed.
    func categoryKind(for kind: LedgerTransactionKind) -> LedgerCategoryKind? {
      switch kind {
      case .income: .income
      case .expense: .expense
      case .transfer, .adjustment: nil
      }
    }

    /// The written instant is kept when it still matches the written local time and offset.
    /// When someone edited the local time, the instant is worked out again from the time zone.
    mutating func temporal(_ table: Table, _ row: (number: Int, cells: [String])) -> SourceTemporal? {
      guard let text = required(table, row, "local_date_time") else { return nil }
      guard let local = Self.parseLocalDateTime(text) else {
        report(
          table.sheet, row.number, "local_date_time",
          "“\(text)” is not a date and time like 2026-03-01 09:30:00.000.")
        return nil
      }
      guard let precision = choice(table, row, "precision", SourceTemporalPrecision.self) else {
        return nil
      }
      let identifier = optional(table, row, "time_zone")
      let offsetText = optional(table, row, "utc_offset_seconds")
      let offset = offsetText.flatMap { Int($0) }
      if offsetText != nil, offset == nil {
        report(table.sheet, row.number, "utc_offset_seconds", "“\(offsetText!)” is not a whole number.")
        return nil
      }
      if identifier == nil, offset == nil {
        report(table.sheet, row.number, "time_zone", "Give a time zone or a UTC offset.")
        return nil
      }
      if let offset, let instantText = optional(table, row, "instant_ms"),
        let milliseconds = Int64(instantText)
      {
        let instant = UTCInstant(epochMilliseconds: milliseconds)
        let exact: SourceTemporal?
        if let identifier {
          exact = try? SourceTemporal.validatingPersistedIANA(
            instant: instant, localDateTime: local, identifier: identifier, precision: precision,
            resolvedOffsetSeconds: offset)
        } else {
          exact = (try? SourceTimeZone(fixedOffsetSeconds: offset)).flatMap {
            try? SourceTemporal(
              instant: instant, localDateTime: local, timeZone: $0, precision: precision,
              resolvedOffsetSeconds: offset)
          }
        }
        if let exact { return exact }
      }
      do {
        let zone =
          try identifier.map { try SourceTimeZone(ianaIdentifier: $0) }
          ?? SourceTimeZone(fixedOffsetSeconds: offset!)
        return try SourceTemporal(resolving: local, in: zone, precision: precision)
      } catch SourceTemporalError.ambiguousLocalTime {
        report(
          table.sheet, row.number, "local_date_time",
          "This local time happens twice in \(identifier ?? "the time zone"); keep the exported instant_ms and utc_offset_seconds to say which.")
      } catch SourceTemporalError.nonexistentLocalTime {
        report(
          table.sheet, row.number, "local_date_time",
          "This local time does not exist in \(identifier ?? "the time zone") (the clocks skip it).")
      } catch SourceTemporalError.precisionMismatch {
        report(
          table.sheet, row.number, "precision",
          "The time has more detail than “\(precision.rawValue)” precision allows.")
      } catch {
        report(table.sheet, row.number, "time_zone", "The time zone or offset is not valid.")
      }
      return nil
    }

    /// "YYYY-MM-DD", optionally followed by " HH:MM", ":SS" and ".mmm" (a "T" also works).
    static func parseLocalDateTime(_ text: String) -> SourceLocalDateTime? {
      let parts = text.split(whereSeparator: { $0 == " " || $0 == "T" }).map(String.init)
      guard (1...2).contains(parts.count) else { return nil }
      let dateParts = parts[0].split(separator: "-", omittingEmptySubsequences: false)
      guard dateParts.count == 3, dateParts[0].count == 4, dateParts[1].count == 2,
        dateParts[2].count == 2, let year = Int(dateParts[0]), let month = Int(dateParts[1]),
        let day = Int(dateParts[2]), let date = try? SourceLocalDate(year: year, month: month, day: day)
      else { return nil }
      guard parts.count == 2 else { return try? SourceLocalDateTime(date: date) }
      let secondsSplit = parts[1].split(separator: ".", omittingEmptySubsequences: false)
      guard (1...2).contains(secondsSplit.count) else { return nil }
      let clock = secondsSplit[0].split(separator: ":", omittingEmptySubsequences: false)
      guard (2...3).contains(clock.count), clock.allSatisfy({ $0.count == 2 }),
        let hour = Int(clock[0]), let minute = Int(clock[1])
      else { return nil }
      let second = clock.count == 3 ? Int(clock[2]) : 0
      var millisecond: Int? = 0
      if secondsSplit.count == 2 {
        let fraction = secondsSplit[1]
        guard fraction.count == 3, clock.count == 3 else { return nil }
        millisecond = Int(fraction)
      }
      guard let second, let millisecond else { return nil }
      return try? SourceLocalDateTime(
        date: date, hour: hour, minute: minute, second: second, millisecond: millisecond)
    }
  }
}
