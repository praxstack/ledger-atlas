import LedgerCore
import LedgerStore
import SwiftUI

/// Daily, Calendar, Monthly, Total and Note views over `LedgerBrowser`, with filters, paging and
/// a selection that stays on its page after an edit.
struct LedgerBrowseList: View {
  let transactions: [LedgerTransactionSnapshot]
  let hiddenIDs: Set<String>
  let accounts: [LedgerAccount]
  let categories: [LedgerCategory]
  let splitPurchases: [LedgerSplitPurchase]
  @Binding var selectedID: String?
  let copy: (String) -> Void
  let tombstone: (String) -> Void
  var tags: [LedgerTag] = []
  /// Tag links by revision ID, from the snapshot.
  var revisionTags: [String: LedgerTagLinks] = [:]
  var editTags: ((String) -> Void)?
  var saveAsTemplate: ((String) -> Void)?

  @State private var browser = LedgerBrowser(transactions: [])
  @State private var mode: LedgerBrowseMode = .daily
  @State private var filter = LedgerBrowseFilter()
  @State private var pageIndex = 0
  @State private var page: LedgerBrowsePage?
  @State private var totals: [LedgerBrowseTotal] = []
  @State private var calendarMonth: (year: Int, month: Int)?
  @State private var calendarDays: [LedgerBrowseDay] = []

  private var accountNames: [String: String] {
    Dictionary(accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
  }

  private var categoryNames: [String: String] {
    Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
  }

  private var tagNames: [String: String] {
    Dictionary(tags.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Picker("Ledger view", selection: $mode) {
        ForEach(LedgerBrowseMode.allCases, id: \.self) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .accessibilityLabel("Ledger view")
      .padding(.horizontal, 16)
      filterBar.padding(.horizontal, 16)
      if mode == .calendar { calendarGrid.padding(.horizontal, 16) }
      totalsLine.padding(.horizontal, 16)
      content
      pager.padding(.horizontal, 16)
    }
    .onAppear { rebuild() }
    .onChange(of: transactions) { _, _ in rebuild() }
    .onChange(of: hiddenIDs) { _, _ in rebuild() }
    .onChange(of: revisionTags) { _, _ in rebuild() }
    .onChange(of: tags) { _, _ in rebuild() }
    .onChange(of: mode) { _, _ in
      if mode != .calendar { filter.day = nil }
      refresh(keepingSelection: true)
    }
    .onChange(of: filter) { _, _ in refresh(keepingSelection: true) }
    .onChange(of: pageIndex) { _, _ in refreshPage() }
  }

  // MARK: Filters

  private var filterBar: some View {
    HStack(spacing: 8) {
      TextField("Search notes, amounts, accounts", text: $filter.text)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("Search ledger")
      Picker("Account", selection: $filter.accountID) {
        Text("All accounts").tag(String?.none)
        ForEach(accounts, id: \.id) { account in
          Text(account.name).tag(Optional(account.id))
        }
      }
      .accessibilityLabel("Filter by account")
      .frame(maxWidth: 180)
      Picker("Category", selection: $filter.categoryID) {
        Text("All categories").tag(String?.none)
        ForEach(categories, id: \.id) { category in
          Text(category.name).tag(Optional(category.id))
        }
      }
      .accessibilityLabel("Filter by category")
      .frame(maxWidth: 180)
      if !tags.isEmpty {
        Picker("Tag", selection: $filter.tagID) {
          Text("All tags").tag(String?.none)
          ForEach(AnnotationPresentation.sortedTags(tags), id: \.id) { tag in
            Text(tag.name).tag(Optional(tag.id))
          }
        }
        .accessibilityLabel("Filter by tag")
        .frame(maxWidth: 160)
      }
      Menu("Kinds") {
        ForEach(LedgerTransactionKind.allCases, id: \.self) { kind in
          Toggle(kind.rawValue.capitalized, isOn: kindBinding(kind))
        }
        Divider()
        Toggle("Show closed", isOn: $filter.includesClosed)
      }
      .accessibilityLabel("Filter by kind")
      .fixedSize()
      if filter.isActive {
        Button("Clear filters") { filter = LedgerBrowseFilter() }
          .accessibilityLabel("Clear filters")
          .keyboardShortcut("k", modifiers: [.command, .shift])
      }
    }
  }

  private func kindBinding(_ kind: LedgerTransactionKind) -> Binding<Bool> {
    Binding(
      get: { filter.kinds.contains(kind) },
      set: { isOn in
        if isOn { filter.kinds.insert(kind) } else { filter.kinds.remove(kind) }
      })
  }

  private var totalsLine: some View {
    let text = Self.describe(totals)
    return Text(page.map { "\($0.matchCount) transactions" } ?? "")
      + Text(text.isEmpty ? "" : " · \(text)")
  }

  // MARK: Calendar

  private var calendarGrid: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Button {
          shiftMonth(by: -1)
        } label: {
          Image(systemName: "chevron.left")
        }
        .accessibilityLabel("Previous month")
        Text(monthTitle).font(.headline)
        Button {
          shiftMonth(by: 1)
        } label: {
          Image(systemName: "chevron.right")
        }
        .accessibilityLabel("Next month")
        Spacer()
        if let day = filter.day {
          Button("Show whole month") { filter.day = nil }
            .accessibilityLabel("Show every day, not only \(Self.dayTitle(day))")
        }
      }
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4)
      {
        ForEach(calendarDays, id: \.date) { day in
          Button {
            filter.day = filter.day == day.date ? nil : day.date
          } label: {
            VStack(spacing: 2) {
              Text("\(day.date.day)").font(.body.monospacedDigit())
              Text("\(day.count)").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(
              filter.day == day.date ? Color.accentColor.opacity(0.2) : Color.clear,
              in: RoundedRectangle(cornerRadius: 6))
          }
          .buttonStyle(.plain)
          .accessibilityLabel(
            "\(Self.dayTitle(day.date)), \(day.count) transactions. \(Self.describe(day.totals))")
          .accessibilityAddTraits(filter.day == day.date ? .isSelected : [])
        }
      }
      if calendarDays.isEmpty {
        Text("No transactions this month.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var monthTitle: String {
    guard let calendarMonth else { return "" }
    return String(format: "%04d-%02d", calendarMonth.year, calendarMonth.month)
  }

  private func shiftMonth(by delta: Int) {
    guard let current = calendarMonth else { return }
    let index = current.year * 12 + (current.month - 1) + delta
    calendarMonth = (index / 12, index % 12 + 1)
    filter.day = nil
    refreshCalendar()
  }

  // MARK: Entries

  @ViewBuilder private var content: some View {
    if let page, page.matchCount == 0, filter.isActive || mode == .note {
      VStack(spacing: 12) {
        ContentUnavailableView(
          mode == .note && !filter.isActive ? "No notes" : "No matching transactions",
          systemImage: "line.3.horizontal.decrease.circle",
          description: Text(
            mode == .note && !filter.isActive
              ? "Transactions with a note appear here."
              : "Nothing matches these filters."))
        if filter.isActive {
          Button("Clear filters") { filter = LedgerBrowseFilter() }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollViewReader { proxy in
        List(selection: $selectedID) {
          ForEach(page?.sections ?? []) { section in
            Section {
              ForEach(section.entries) { entry in
                row(entry)
                  .tag(entry.id)
                  .id(entry.id)
                  .contextMenu {
                    Button("Copy transaction") { copy(entry.id) }
                    if let editTags, entry.lifecycle == .active {
                      Button("Edit tags…") { editTags(entry.id) }
                    }
                    if let saveAsTemplate, entry.lifecycle == .active {
                      Button("Save as template…") { saveAsTemplate(entry.id) }
                    }
                    Button("Close transaction", role: .destructive) { tombstone(entry.id) }
                  }
              }
            } header: {
              sectionHeader(section)
            }
          }
          if !splitPurchases.isEmpty, page?.pageIndex == 0 {
            Section("Split purchases") {
              ForEach(splitPurchases, id: \.id) { purchase in
                splitRow(purchase)
              }
            }
          }
        }
        .onChange(of: page) { _, _ in
          if let selectedID, page?.entries.contains(where: { $0.id == selectedID }) == true {
            proxy.scrollTo(selectedID)
          }
        }
      }
    }
  }

  private func sectionHeader(_ section: LedgerBrowseSection) -> some View {
    let title = section.id == "total" ? "All transactions" : section.id
    let totals = Self.describe(section.totals)
    return HStack {
      Text(title)
      Spacer()
      if !totals.isEmpty { Text(totals).font(.caption.monospacedDigit()) }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(totals.isEmpty ? title : "\(title), \(totals)")
  }

  private func row(_ entry: LedgerBrowseEntry) -> some View {
    let category = entry.categoryID.flatMap { categoryNames[$0] }
    let account = entry.accountIDs.compactMap { accountNames[$0] }.joined(separator: " → ")
    let title = category ?? entry.kind.rawValue.capitalized
    let amount = "\(entry.amount.amount.rawLiteral) \(entry.amount.unitCode)"
    let time = String(format: "%02d:%02d", entry.occurredAt.hour, entry.occurredAt.minute)
    let detail = [amount, account.isEmpty ? nil : account, time].compactMap { $0 }
      .joined(separator: " · ")
    let markers = entry.indicators.map(Self.indicatorLabel).joined(separator: ", ")
    let tagLine = entry.tagIDs.compactMap { tagNames[$0] }.sorted {
      $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }.map { "#\($0)" }.joined(separator: " ")
    return HStack(alignment: .firstTextBaseline, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).strikethrough(entry.lifecycle == .tombstoned)
        Text(detail).font(.caption).foregroundStyle(.secondary)
        if let note = entry.note {
          Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        if !tagLine.isEmpty {
          Text(tagLine).font(.caption).foregroundStyle(.tint).lineLimit(1)
        }
      }
      Spacer()
      HStack(spacing: 4) {
        ForEach(entry.indicators, id: \.self) { indicator in
          Image(systemName: Self.indicatorSymbol(indicator))
            .foregroundStyle(.secondary)
            .help(Self.indicatorLabel(indicator))
        }
      }
      .accessibilityHidden(true)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      [
        title, detail, entry.note, tagLine.isEmpty ? nil : "tags \(tagLine)",
        markers.isEmpty ? nil : markers,
      ].compactMap { $0 }
        .joined(separator: ", "))
  }

  private func splitRow(_ purchase: LedgerSplitPurchase) -> some View {
    DisclosureGroup {
      ForEach(purchase.lines, id: \.id) { line in
        let category = categoryNames[line.categoryID] ?? "Category"
        let text =
          "\(line.description ?? "Split line"), \(category), \(line.amount.amount.rawLiteral) \(line.amount.unitCode)"
        Text(text).font(.caption).accessibilityLabel(text)
      }
    } label: {
      Text(
        "Split purchase · \(purchase.parentAmount.amount.rawLiteral) \(purchase.parentAmount.unitCode) · \(purchase.lines.count) categories"
      )
    }
    .accessibilityLabel(
      "Split purchase, \(purchase.parentAmount.amount.rawLiteral) \(purchase.parentAmount.unitCode), \(purchase.lines.count) categories"
    )
  }

  @ViewBuilder private var pager: some View {
    if let page, page.pageCount > 1 {
      HStack {
        Button("Previous page") { pageIndex = max(0, page.pageIndex - 1) }
          .disabled(page.pageIndex == 0)
          .keyboardShortcut("[", modifiers: .command)
        Text("Page \(page.pageIndex + 1) of \(page.pageCount)")
          .font(.caption.monospaced())
          .accessibilityLabel("Page \(page.pageIndex + 1) of \(page.pageCount)")
        Button("Next page") { pageIndex = min(page.pageCount - 1, page.pageIndex + 1) }
          .disabled(page.pageIndex + 1 >= page.pageCount)
          .keyboardShortcut("]", modifiers: .command)
      }
    }
  }

  // MARK: State

  /// New snapshot (after an edit, copy or close): re-sort and keep the selection on screen.
  private func rebuild() {
    browser = LedgerBrowser(
      transactions: transactions, hiding: hiddenIDs, accountNames: accountNames,
      categoryNames: categoryNames, revisionTags: revisionTags, tagNames: tagNames)
    if calendarMonth == nil, let newest = browser.entries.first?.occurredAt.date {
      calendarMonth = (newest.year, newest.month)
    }
    refresh(keepingSelection: true)
  }

  private func refresh(keepingSelection: Bool) {
    if keepingSelection, let selectedID,
      let index = browser.pageIndex(of: selectedID, mode: mode, filter: filter)
    {
      pageIndex = index
    } else {
      pageIndex = 0
    }
    totals = browser.totals(mode: mode, filter: filter)
    refreshPage()
    refreshCalendar()
  }

  private func refreshPage() {
    page = browser.page(mode: mode, filter: filter, pageIndex: pageIndex)
  }

  private func refreshCalendar() {
    guard mode == .calendar, let calendarMonth else { return }
    calendarDays = browser.calendar(
      year: calendarMonth.year, month: calendarMonth.month, filter: filter)
  }

  // MARK: Text

  static func describe(_ totals: [LedgerBrowseTotal]) -> String {
    totals.map { total in
      let income = total.income?.rawLiteral ?? "unavailable"
      let expense = total.expense?.rawLiteral ?? "unavailable"
      return "\(total.unitCode) in \(income), out \(expense)"
    }
    .joined(separator: "; ")
  }

  static func dayTitle(_ date: SourceLocalDate) -> String {
    String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
  }

  static func indicatorSymbol(_ indicator: LedgerBrowseIndicator) -> String {
    switch indicator {
    case .note: "note.text"
    case .edited: "pencil"
    case .closed: "xmark.circle"
    case .transfer: "arrow.left.arrow.right"
    case .conversion: "dollarsign.arrow.circlepath"
    }
  }

  static func indicatorLabel(_ indicator: LedgerBrowseIndicator) -> String {
    switch indicator {
    case .note: "has a note"
    case .edited: "edited"
    case .closed: "closed"
    case .transfer: "transfer"
    case .conversion: "currency conversion"
    }
  }
}
