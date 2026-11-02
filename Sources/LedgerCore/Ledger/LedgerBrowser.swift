import Foundation

/// The five ways the ledger can be browsed.
public enum LedgerBrowseMode: String, CaseIterable, Sendable {
  case daily, calendar, monthly, total, note

  public var title: String {
    switch self {
    case .daily: "Daily"
    case .calendar: "Calendar"
    case .monthly: "Monthly"
    case .total: "Total"
    case .note: "Note"
    }
  }
}

/// Narrows the ledger. Empty fields mean "no limit".
public struct LedgerBrowseFilter: Equatable, Sendable {
  public var text: String
  public var accountID: String?
  public var categoryID: String?
  public var kinds: Set<LedgerTransactionKind>
  public var includesClosed: Bool
  /// A calendar day picked by the person; only that day's entries match.
  public var day: SourceLocalDate?
  /// Only entries whose current revision carries this tag match.
  public var tagID: String?

  public init(
    text: String = "", accountID: String? = nil, categoryID: String? = nil,
    kinds: Set<LedgerTransactionKind> = [], includesClosed: Bool = true,
    day: SourceLocalDate? = nil, tagID: String? = nil
  ) {
    self.text = text
    self.accountID = accountID
    self.categoryID = categoryID
    self.kinds = kinds
    self.includesClosed = includesClosed
    self.day = day
    self.tagID = tagID
  }

  /// True when anything narrows the ledger, so an empty result means "no match", not "empty".
  public var isActive: Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || accountID != nil
      || categoryID != nil || !kinds.isEmpty || !includesClosed || day != nil
      || tagID != nil
  }
}

/// Small markers shown next to an entry.
public enum LedgerBrowseIndicator: String, CaseIterable, Sendable {
  case note, edited, closed, transfer, conversion
}

public struct LedgerBrowseEntry: Identifiable, Equatable, Sendable {
  public let id: String
  public let occurredAt: SourceLocalDateTime
  public let kind: LedgerTransactionKind
  public let lifecycle: LedgerLifecycleState
  public let amount: CurrencyAmount
  public let note: String?
  public let categoryID: String?
  public let accountIDs: [String]
  public let revision: Int
  public let indicators: [LedgerBrowseIndicator]
  /// Tags on the current revision, sorted by ID.
  public let tagIDs: [String]
  /// Lowercased text the search box matches against.
  let searchText: String
}

/// Income and expense for one currency. Transfers and adjustments move money between
/// accounts, so they are not counted here. A nil total went past the exact-decimal limits and
/// is shown as unavailable rather than as a wrong number.
public struct LedgerBrowseTotal: Equatable, Sendable {
  public let unitCode: String
  public let income: ExactDecimal?
  public let expense: ExactDecimal?
}

public struct LedgerBrowseSection: Identifiable, Equatable, Sendable {
  /// "2026-11-02" (daily, calendar, note), "2026-11" (monthly) or "total".
  public let id: String
  public let entries: [LedgerBrowseEntry]
  /// Totals for every matching entry in this section, including ones on other pages.
  public let totals: [LedgerBrowseTotal]
}

public struct LedgerBrowsePage: Equatable, Sendable {
  public let sections: [LedgerBrowseSection]
  public let pageIndex: Int
  public let pageCount: Int
  public let matchCount: Int

  public var entries: [LedgerBrowseEntry] { sections.flatMap(\.entries) }
}

public struct LedgerBrowseDay: Equatable, Sendable {
  public let date: SourceLocalDate
  public let count: Int
  public let totals: [LedgerBrowseTotal]
}

/// Sorts the ledger once, newest first, then pages, filters, groups and totals it.
/// Everything here is pure so a 100,000-entry ledger can be checked without a UI.
public struct LedgerBrowser: Sendable {
  public static let defaultPageSize = 100

  /// Newest first; ties keep a stable order by id so positions never shuffle.
  public let entries: [LedgerBrowseEntry]
  private let positionByID: [String: Int]

  public init(
    transactions: [LedgerTransactionSnapshot], hiding hiddenIDs: Set<String> = [],
    accountNames: [String: String] = [:], categoryNames: [String: String] = [:],
    revisionTags: [String: LedgerTagLinks] = [:], tagNames: [String: String] = [:]
  ) {
    var built: [LedgerBrowseEntry] = []
    built.reserveCapacity(transactions.count)
    for transaction in transactions where !hiddenIDs.contains(transaction.id) {
      let revision = transaction.currentRevision
      let draft = revision.draft
      guard let first = draft.effects.first else { continue }
      var indicators: [LedgerBrowseIndicator] = []
      if draft.note != nil { indicators.append(.note) }
      if revision.revision > 1 { indicators.append(.edited) }
      if revision.lifecycle == .tombstoned { indicators.append(.closed) }
      if draft.kind == .transfer { indicators.append(.transfer) }
      if draft.sourceLiterals.contains(where: { $0.field == "conversion.rate" }) {
        indicators.append(.conversion)
      }
      let accountIDs = draft.effects.map(\.accountID)
      var words = [
        draft.kind.rawValue, first.amount.amount.rawLiteral, first.amount.unitCode,
        draft.note ?? "",
      ]
      words += accountIDs.compactMap { accountNames[$0] }
      if let categoryID = draft.categoryID, let name = categoryNames[categoryID] {
        words.append(name)
      }
      let tagIDs = revisionTags[revision.id]?.tagIDs ?? []
      words += tagIDs.compactMap { tagNames[$0] }
      built.append(
        LedgerBrowseEntry(
          id: transaction.id, occurredAt: draft.occurredAt.localDateTime, kind: draft.kind,
          lifecycle: revision.lifecycle, amount: first.amount, note: draft.note,
          categoryID: draft.categoryID, accountIDs: accountIDs, revision: revision.revision,
          indicators: indicators, tagIDs: tagIDs, searchText: words.joined(separator: " ").lowercased()))
    }
    built.sort { lhs, rhs in
      lhs.occurredAt != rhs.occurredAt ? lhs.occurredAt > rhs.occurredAt : lhs.id < rhs.id
    }
    entries = built
    var positions: [String: Int] = [:]
    positions.reserveCapacity(built.count)
    for (index, entry) in built.enumerated() { positions[entry.id] = index }
    positionByID = positions
  }

  public func entry(id: String) -> LedgerBrowseEntry? {
    positionByID[id].map { entries[$0] }
  }

  /// Indexes into `entries` that match, in display order.
  public func matches(mode: LedgerBrowseMode, filter: LedgerBrowseFilter) -> [Int] {
    let needles = filter.text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    var result: [Int] = []
    result.reserveCapacity(entries.count)
    for (index, entry) in entries.enumerated() {
      if mode == .note, entry.note == nil { continue }
      if !filter.includesClosed, entry.lifecycle == .tombstoned { continue }
      if !filter.kinds.isEmpty, !filter.kinds.contains(entry.kind) { continue }
      if let accountID = filter.accountID, !entry.accountIDs.contains(accountID) { continue }
      if let categoryID = filter.categoryID, entry.categoryID != categoryID { continue }
      if let day = filter.day, entry.occurredAt.date != day { continue }
      if let tagID = filter.tagID, !entry.tagIDs.contains(tagID) { continue }
      if !needles.allSatisfy({ entry.searchText.contains($0) }) { continue }
      result.append(index)
    }
    return result
  }

  public func page(
    mode: LedgerBrowseMode, filter: LedgerBrowseFilter = .init(), pageIndex: Int,
    pageSize: Int = defaultPageSize
  ) -> LedgerBrowsePage {
    let size = max(1, pageSize)
    let matched = matches(mode: mode, filter: filter)
    let pageCount = max(1, (matched.count + size - 1) / size)
    let index = min(max(0, pageIndex), pageCount - 1)
    let slice = matched.dropFirst(index * size).prefix(size)

    // Group the page into sections. Section totals cover the whole section, including entries
    // on neighbouring pages; matches are sorted, so only the stretch around this page can share
    // its first or last section.
    var sections: [LedgerBrowseSection] = []
    if !slice.isEmpty {
      let start = index * size
      let end = start + slice.count - 1
      var low = start
      while low > 0, Self.sameSection(entries[matched[low - 1]], entries[matched[start]], mode) {
        low -= 1
      }
      var high = end
      while high + 1 < matched.count,
        Self.sameSection(entries[matched[high + 1]], entries[matched[end]], mode)
      {
        high += 1
      }
      var groupStart = low
      for position in low...high
      where position == high
        || !Self.sameSection(entries[matched[position]], entries[matched[position + 1]], mode)
      {
        let group = matched[groupStart...position]
        groupStart = position + 1
        var totals = TotalsAccumulator()
        for match in group { totals.add(entries[match]) }
        let visible = group.indices.filter { $0 >= start && $0 <= end }.map { entries[matched[$0]] }
        guard let firstVisible = visible.first else { continue }
        sections.append(
          .init(
            id: Self.sectionKey(firstVisible, mode: mode), entries: visible,
            totals: totals.totals))
      }
    }
    return LedgerBrowsePage(
      sections: sections, pageIndex: index, pageCount: pageCount, matchCount: matched.count)
  }

  /// Income and expense for every matching entry. Separate from `page` so turning a page does
  /// not re-add the whole ledger; recompute only when the mode or filter changes.
  public func totals(mode: LedgerBrowseMode, filter: LedgerBrowseFilter = .init())
    -> [LedgerBrowseTotal]
  {
    var overall = TotalsAccumulator()
    for position in matches(mode: mode, filter: filter) { overall.add(entries[position]) }
    return overall.totals
  }

  /// The page that shows `id`, so editing returns to the same place. Nil when the entry is gone
  /// or filtered out.
  public func pageIndex(
    of id: String, mode: LedgerBrowseMode, filter: LedgerBrowseFilter = .init(),
    pageSize: Int = defaultPageSize
  ) -> Int? {
    guard let position = positionByID[id] else { return nil }
    let matched = matches(mode: mode, filter: filter)
    guard let offset = Self.binarySearch(matched, for: position) else { return nil }
    return offset / max(1, pageSize)
  }

  /// One row per day of the month that has matching entries.
  public func calendar(year: Int, month: Int, filter: LedgerBrowseFilter = .init())
    -> [LedgerBrowseDay]
  {
    var dayFilter = filter
    dayFilter.day = nil
    var byDay: [SourceLocalDate: (count: Int, totals: TotalsAccumulator)] = [:]
    for position in matches(mode: .calendar, filter: dayFilter) {
      let entry = entries[position]
      let date = entry.occurredAt.date
      guard date.year == year, date.month == month else { continue }
      var day = byDay[date] ?? (0, TotalsAccumulator())
      day.count += 1
      day.totals.add(entry)
      byDay[date] = day
    }
    return byDay.keys.sorted().map {
      LedgerBrowseDay(date: $0, count: byDay[$0]!.count, totals: byDay[$0]!.totals.totals)
    }
  }

  private static func sameSection(
    _ lhs: LedgerBrowseEntry, _ rhs: LedgerBrowseEntry, _ mode: LedgerBrowseMode
  ) -> Bool {
    let left = lhs.occurredAt.date
    let right = rhs.occurredAt.date
    switch mode {
    case .total: return true
    case .monthly: return left.year == right.year && left.month == right.month
    case .daily, .calendar, .note: return left == right
    }
  }

  static func sectionKey(_ entry: LedgerBrowseEntry, mode: LedgerBrowseMode) -> String {
    let date = entry.occurredAt.date
    switch mode {
    case .monthly:
      return String(format: "%04d-%02d", date.year, date.month)
    case .total:
      return "total"
    case .daily, .calendar, .note:
      return String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
    }
  }

  private static func binarySearch(_ sorted: [Int], for value: Int) -> Int? {
    var low = 0
    var high = sorted.count - 1
    while low <= high {
      let middle = (low + high) / 2
      if sorted[middle] == value { return middle }
      if sorted[middle] < value { low = middle + 1 } else { high = middle - 1 }
    }
    return nil
  }
}

private struct TotalsAccumulator {
  private var income: [String: ExactDecimal?] = [:]
  private var expense: [String: ExactDecimal?] = [:]

  mutating func add(_ entry: LedgerBrowseEntry) {
    guard entry.lifecycle == .active else { return }
    let unit = entry.amount.unitCode
    switch entry.kind {
    case .income:
      income[unit] = Self.sum(income[unit], entry.amount.amount)
    case .expense:
      expense[unit] = Self.sum(expense[unit], entry.amount.amount)
    case .transfer, .adjustment:
      return
    }
  }

  var totals: [LedgerBrowseTotal] {
    let zero = try? ExactDecimal("0")
    return Set(income.keys).union(expense.keys).sorted().map {
      LedgerBrowseTotal(
        unitCode: $0, income: income[$0] ?? zero, expense: expense[$0] ?? zero)
    }
  }

  /// `running` is nil when this unit has no total yet, and `.some(nil)` once it overflowed.
  private static func sum(_ running: ExactDecimal??, _ value: ExactDecimal) -> ExactDecimal? {
    guard let running else { return value }
    guard let running else { return nil }
    return try? running.adding(value)
  }
}
