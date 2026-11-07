import AppKit
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
  /// The selected entries. One shows in the inspector; more than one shows the bulk bar (#168).
  @Binding var selectedIDs: Set<String>
  let copy: (String) -> Void
  let tombstone: (String) -> Void
  var tags: [LedgerTag] = []
  /// Tag links by revision ID, from the snapshot.
  var revisionTags: [String: LedgerTagLinks] = [:]
  var editTags: ((String) -> Void)?
  var saveAsTemplate: ((String) -> Void)?
  var editSplit: ((LedgerSplitPurchase) -> Void)?
  var closeSplit: ((LedgerSplitPurchase) -> Void)?
  /// A bulk change on the given entries (#168). Nil while the ledger is read-only.
  var bulkEdit: ((LedgerBulkChange, [String]) -> Void)?

  @Environment(\.ledgerFormatter) private var formatter
  /// The inspector as the person last left it, kept across visits and launches: -1 until they
  /// touch it, then 0 hidden or 1 shown. Until then the first settled layout picks a default by
  /// width, so a small display is not left with a cramped table (see `body`).
  @AppStorage(LedgerBrowseList.inspectorDefaultsKey) private var inspectorChoiceRaw = -1
  /// The latest detail width, measured while the inspector is hidden.
  @State private var measuredWidth: CGFloat = 0
  @FocusState private var searchIsFocused: Bool
  @FocusState private var focusedFilter: String?
  @State private var browser = LedgerBrowser(transactions: [])
  @State private var mode: LedgerBrowseMode = .daily
  @State private var filter = LedgerBrowseFilter()
  @State private var pageIndex = 0
  @State private var page: LedgerBrowsePage?
  @State private var totals: [LedgerBrowseTotal] = []
  /// How many entries the view matches across all pages, for "Select All N".
  @State private var matchCount = 0
  @State private var calendarMonth: (year: Int, month: Int)?
  @State private var calendarDays: [LedgerBrowseDay] = []
  /// True until the first index of this ledger is built; large ledgers build off the main thread.
  @State private var isLoading = true
  /// Bumped on every rebuild so a slower, older build never replaces a newer one.
  @State private var buildGeneration = 0

  /// The detail width that leaves room for the table beside a 320 pt inspector. Below it the
  /// inspector starts hidden; ⌥⌘I still shows it.
  static let inspectorAutoShowWidth: CGFloat = 780
  static let inspectorDefaultsKey = "transactions.inspector"
  static let showInspectorTitle = "Show Inspector"
  static let hideInspectorTitle = "Hide Inspector"

  private var inspectorChoice: Bool? {
    get { inspectorChoiceRaw < 0 ? nil : inspectorChoiceRaw == 1 }
    nonmutating set { inspectorChoiceRaw = newValue.map { $0 ? 1 : 0 } ?? -1 }
  }

  private var accountNames: [String: String] {
    Dictionary(accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
  }

  private var categoryNames: [String: String] {
    Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
  }

  private var tagNames: [String: String] {
    Dictionary(tags.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
  }

  /// The one selected entry; nil when none or several are selected.
  private var selectedID: String? { selectedIDs.count == 1 ? selectedIDs.first : nil }

  private var selectedEntry: LedgerBrowseEntry? {
    guard let selectedID else { return nil }
    return page?.entries.first { $0.id == selectedID }
  }

  private var showsInspector: Binding<Bool> {
    Binding(get: { inspectorChoice ?? false }, set: { inspectorChoice = $0 })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      controls
        .padding(.horizontal, LedgerTheme.Space.l)
        .padding(.top, LedgerTheme.Space.m)
        .padding(.bottom, LedgerTheme.Space.s)
      if mode == .calendar {
        calendarGrid
          .padding(.horizontal, LedgerTheme.Space.l)
          .padding(.bottom, LedgerTheme.Space.s)
      }
      summaryStrip
        .padding(.horizontal, LedgerTheme.Space.l)
        .padding(.bottom, LedgerTheme.Space.m)
      bulkBar
      Divider().overlay(LedgerTheme.hairline)
      content
      pager
    }
    .ledgerCanvas()
    .navigationSubtitle(subtitle)
    // Measured while the inspector is still hidden, so this is the whole detail width.
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredWidth = $0 }
    .task(id: measuredWidth > 0) {
      // The split view settles its columns over the first frames, so the default waits for a
      // moment and reads the width then. It decides once; after that only the toggle counts.
      guard inspectorChoice == nil, measuredWidth > 0 else { return }
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled, inspectorChoice == nil, measuredWidth > 0 else { return }
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        inspectorChoice = measuredWidth >= Self.inspectorAutoShowWidth
      }
    }
    .inspector(isPresented: showsInspector) {
      LedgerTransactionInspector(
        entry: selectedEntry, accountNames: accountNames, categoryNames: categoryNames,
        tagNames: tagNames)
        .inspectorColumnWidth(min: 260, ideal: LedgerTheme.Metrics.inspectorWidth, max: 400)
    }
    .toolbar {
      // The view switcher sits in the toolbar like any Mac app's (Mail, Finder), which keeps
      // the content for the filters, the totals and the table.
      ToolbarItem(placement: .principal) { modePicker }
      ToolbarItem {
        // A toolbar item speaks its label's title (an accessibility label is not used there), so
        // the title itself says what pressing it does.
        Button {
          showsInspector.wrappedValue.toggle()
          // Opening the inspector on nothing shows an empty panel; show the first entry.
          if showsInspector.wrappedValue, selectedIDs.isEmpty, let first = page?.entries.first?.id {
            selectedIDs = [first]
          }
        } label: {
          Label(
            showsInspector.wrappedValue ? Self.hideInspectorTitle : Self.showInspectorTitle,
            systemImage: "sidebar.trailing")
        }
        .accessibilityLabel(
          showsInspector.wrappedValue ? Self.hideInspectorTitle : Self.showInspectorTitle)
        .help("Show or hide transaction details (⌥⌘I)")
        .keyboardShortcut("i", modifiers: [.command, .option])
      }
    }
    .focusedSceneValue(\.ledgerViewCSV, csvExport)
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

  /// File > Export > CSV: every row this view matches (all pages), in the order shown (#170).
  private var csvExport: LedgerViewCSV {
    let browser = browser
    let mode = mode
    let filter = filter
    let transactions = transactions
    let revisionTags = revisionTags
    let names = LedgerCSVExport.Names(
      accounts: accountNames, categories: categories, tags: tagNames)
    return LedgerViewCSV(modeName: mode.rawValue) {
      let byID = Dictionary(
        transactions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      let shown = browser.matches(mode: mode, filter: filter).compactMap {
        byID[browser.entries[$0].id]
      }
      return LedgerCSVExport.data(shown, names: names, revisionTags: revisionTags)
    }
  }

  // MARK: Controls

  /// Search and filter chips in one row. The chips scroll sideways rather than widen the
  /// window; the view switcher is in the toolbar.
  private var controls: some View {
    HStack(spacing: LedgerTheme.Space.m) {
      searchField.frame(minWidth: 180, idealWidth: 240, maxWidth: 260)
      filterChips
    }
  }

  private var modePicker: some View {
    Picker("Ledger view", selection: $mode) {
      ForEach(LedgerBrowseMode.allCases, id: \.self) { mode in
        Text(mode.title).tag(mode)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .fixedSize()
    .accessibilityLabel("Ledger view")
  }

  private var searchField: some View {
    HStack(spacing: LedgerTheme.Space.xs) {
      Image(systemName: "magnifyingglass")
        .font(LedgerTheme.Typeface.caption)
        .foregroundStyle(LedgerTheme.inkTertiary)
        .accessibilityHidden(true)
      TextField("Search", text: $filter.text, prompt: Text("Search notes, amounts, accounts"))
        .textFieldStyle(.plain)
        .font(LedgerTheme.Typeface.secondary)
        .focused($searchIsFocused)
        .accessibilityLabel("Search ledger")
      if !filter.text.isEmpty {
        Button {
          filter.text = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(LedgerTheme.Typeface.caption)
            .foregroundStyle(LedgerTheme.inkTertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, LedgerTheme.Space.s)
    .frame(height: 26)
    .background(LedgerTheme.fieldFill, in: .rect(cornerRadius: LedgerTheme.Radius.control))
    .overlay(focusRing(searchIsFocused))
  }

  /// The keyboard focus ring for the plain search field and chips (Full Keyboard Access).
  private func focusRing(_ focused: Bool, ring: Color = LedgerTheme.accent) -> some View {
    RoundedRectangle(cornerRadius: LedgerTheme.Radius.control)
      .strokeBorder(focused ? ring : LedgerTheme.hairline, lineWidth: focused ? 2 : 0.5)
  }

  private var filterChips: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: LedgerTheme.Space.s) {
        filterMenu(accountTitle, active: filter.accountID != nil, label: "Filter by account") {
          Picker("Account", selection: $filter.accountID) {
            Text("All accounts").tag(String?.none)
            ForEach(accounts, id: \.id) { account in
              Text(account.name).tag(Optional(account.id))
            }
          }
          .pickerStyle(.inline)
        }
        filterMenu(categoryTitle, active: filter.categoryID != nil, label: "Filter by category") {
          Picker("Category", selection: $filter.categoryID) {
            Text("All categories").tag(String?.none)
            ForEach(categories, id: \.id) { category in
              Text(category.name).tag(Optional(category.id))
            }
          }
          .pickerStyle(.inline)
        }
        if !tags.isEmpty {
          filterMenu(tagTitle, active: filter.tagID != nil, label: "Filter by tag") {
            Picker("Tag", selection: $filter.tagID) {
              Text("All tags").tag(String?.none)
              ForEach(AnnotationPresentation.sortedTags(tags), id: \.id) { tag in
                Text(tag.name).tag(Optional(tag.id))
              }
            }
            .pickerStyle(.inline)
          }
        }
        filterMenu(
          kindsTitle, active: !filter.kinds.isEmpty || !filter.includesClosed, label: "Filter by kind"
        ) {
          ForEach(LedgerTransactionKind.allCases, id: \.self) { kind in
            Toggle(kind.rawValue.capitalized, isOn: kindBinding(kind))
          }
          Divider()
          Toggle("Show closed", isOn: $filter.includesClosed)
        }
        if filter.isActive {
          Button("Clear filters") { filter = LedgerBrowseFilter() }
            .buttonStyle(.plain)
            .font(LedgerTheme.Typeface.caption)
            .foregroundStyle(LedgerTheme.accent)
            .accessibilityLabel("Clear filters")
            .keyboardShortcut("k", modifiers: [.command, .shift])
        }
      }
    }
  }

  private var accountTitle: String {
    filter.accountID.flatMap { accountNames[$0] } ?? "All accounts"
  }

  private var categoryTitle: String {
    filter.categoryID.flatMap { categoryNames[$0] } ?? "All categories"
  }

  private var tagTitle: String {
    filter.tagID.flatMap { tagNames[$0] }.map { "#\($0)" } ?? "All tags"
  }

  private var kindsTitle: String {
    let kinds = LedgerTransactionKind.allCases.filter { filter.kinds.contains($0) }
      .map { $0.rawValue.capitalized }
    let base = kinds.isEmpty ? "All kinds" : kinds.joined(separator: ", ")
    return filter.includesClosed ? base : "\(base) · open only"
  }

  /// A filter chip that opens a menu. An active filter is told three ways: its own value as the
  /// title, a check mark, and the solid accent fill (on-accent text keeps 4.5:1 and 7:1).
  private func filterMenu<Content: View>(
    _ title: String, active: Bool, label: String, @ViewBuilder content: () -> Content
  ) -> some View {
    Menu {
      content()
    } label: {
      HStack(spacing: LedgerTheme.Space.xs) {
        if active {
          Image(systemName: "checkmark").font(LedgerTheme.Typeface.caption.weight(.bold))
        }
        Text(title).font(LedgerTheme.Typeface.secondary.weight(.medium)).lineLimit(1)
        Image(systemName: "chevron.down").font(LedgerTheme.Typeface.caption.weight(.semibold))
      }
      .foregroundStyle(active ? LedgerTheme.onAccent : LedgerTheme.ink)
      .padding(.horizontal, 10)
      .frame(height: 26)
      .background(
        active ? LedgerTheme.accent : LedgerTheme.fieldFill,
        in: .rect(cornerRadius: LedgerTheme.Radius.control))
      .overlay(focusRing(focusedFilter == label, ring: active ? LedgerTheme.ink : LedgerTheme.accent))
      .contentShape(.rect)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .focused($focusedFilter, equals: label)
    .accessibilityLabel(label)
    .accessibilityValue(title)
  }

  private func kindBinding(_ kind: LedgerTransactionKind) -> Binding<Bool> {
    Binding(
      get: { filter.kinds.contains(kind) },
      set: { isOn in
        if isOn { filter.kinds.insert(kind) } else { filter.kinds.remove(kind) }
      })
  }

  // MARK: Summary

  /// "55 transactions", or "55 of 312 transactions" while a filter or search narrows them.
  private var subtitle: String {
    guard let page else { return "" }
    let total = browser.entries.count
    let noun = page.matchCount == 1 ? "transaction" : "transactions"
    return filter.isActive && total != page.matchCount
      ? "\(page.matchCount) of \(total) \(noun)" : "\(page.matchCount) \(noun)"
  }

  /// Money in, spending and net for what is shown, as figures: the first thing the eye
  /// reads on the screen. One group per currency.
  private var summaryStrip: some View {
    HStack(alignment: .top, spacing: LedgerTheme.Space.xxl) {
      ForEach(totals, id: \.unitCode) { total in
        if let figures = Self.summaryFigures(total) {
          summaryFigure("Money in", figures.income, sign: .always)
          summaryFigure("Spending", figures.expense)
          summaryFigure("Net", figures.net, sign: .always)
        } else {
          Text(Self.describe([total], formatter: formatter))
            .font(LedgerTheme.Typeface.secondary)
            .foregroundStyle(LedgerTheme.inkSecondary)
        }
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }

  /// Money in is green with "+"; spending stays in ink; net carries its sign.
  private func summaryFigure(
    _ label: String, _ amount: CurrencyAmount, sign: LedgerDisplayFormatter.SignStyle = .never
  ) -> some View {
    VStack(alignment: .leading, spacing: LedgerTheme.Space.xxs) {
      Text(label)
        .font(LedgerTheme.Typeface.caption)
        .foregroundStyle(LedgerTheme.inkSecondary)
      MoneyText(amount, size: .figure, sign: sign, tone: sign == .always ? .automatic : .neutral)
    }
  }

  /// In, Out and Net (in minus out) for one currency, when the browser could total it.
  static func summaryFigures(_ total: LedgerBrowseTotal) -> (
    income: CurrencyAmount, expense: CurrencyAmount, net: CurrencyAmount
  )? {
    guard let income = total.income, let expense = total.expense,
      let net = try? income.subtracting(expense),
      let incomeAmount = try? CurrencyAmount(unitCode: total.unitCode, amount: income),
      let expenseAmount = try? CurrencyAmount(unitCode: total.unitCode, amount: expense),
      let netAmount = try? CurrencyAmount(unitCode: total.unitCode, amount: net)
    else { return nil }
    return (incomeAmount, expenseAmount, netAmount)
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
        Text(monthTitle).font(LedgerTheme.Typeface.cardTitle).foregroundStyle(LedgerTheme.ink)
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
              Text("\(day.date.day)").font(LedgerTheme.Typeface.body.monospacedDigit())
                .foregroundStyle(LedgerTheme.ink)
              Text("\(day.count)").font(LedgerTheme.Typeface.caption).monospacedDigit()
                .foregroundStyle(LedgerTheme.inkTertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 36)
            // A soft accent fill and a solid accent outline, so the chosen day stays clear with
            // Increase Contrast on.
            .background(
              filter.day == day.date ? LedgerTheme.accentSoft : LedgerTheme.card,
              in: .rect(cornerRadius: LedgerTheme.Radius.control)
            )
            .overlay(
              RoundedRectangle(cornerRadius: LedgerTheme.Radius.control)
                .strokeBorder(
                  filter.day == day.date ? LedgerTheme.accent : LedgerTheme.hairline,
                  lineWidth: filter.day == day.date ? 2 : 0.5))
          }
          .buttonStyle(.plain)
          .accessibilityLabel(
            "\(Self.dayTitle(day.date)), \(day.count) transactions. \(Self.describe(day.totals, hidingAmounts: formatter.hidesAmounts))")
          .accessibilityAddTraits(filter.day == day.date ? .isSelected : [])
        }
      }
      if calendarDays.isEmpty {
        Text("No transactions this month.")
          .font(LedgerTheme.Typeface.caption)
          .foregroundStyle(LedgerTheme.inkSecondary)
      }
    }
  }

  private var monthTitle: String {
    guard let calendarMonth else { return "" }
    guard let first = try? SourceLocalDate(year: calendarMonth.year, month: calendarMonth.month, day: 1)
    else { return String(format: "%04d-%02d", calendarMonth.year, calendarMonth.month) }
    return formatter.monthTitle(first)
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
    let state = LedgerBrowseContent.state(
      isLoading: isLoading, entryCount: browser.entries.count + splitPurchases.count,
      matchCount: page?.matchCount, filterActive: filter.isActive, mode: mode)
    switch state {
    case .loading:
      ProgressView("Loading ledger…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Loading ledger")
    case .emptyLedger:
      ContentUnavailableView(
        "No transactions yet", systemImage: "tray",
        description: Text("Add income, an expense or a transfer and it appears here."))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .noNotes, .noMatches:
      VStack(spacing: 12) {
        ContentUnavailableView(
          state == .noNotes ? "No notes" : "No matching transactions",
          systemImage: "line.3.horizontal.decrease.circle",
          description: Text(
            state == .noNotes
              ? "Transactions with a note appear here."
              : "Nothing matches these filters."))
        if filter.isActive {
          Button("Clear filters") { filter = LedgerBrowseFilter() }
            .keyboardShortcut(.escape, modifiers: [])
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .entries:
      entryList
    }
  }

  private var entryList: some View {
    ScrollViewReader { proxy in
      List(selection: $selectedIDs) {
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
                .contextMenu {
                  if let editSplit {
                    Button("Edit split…") { editSplit(purchase) }
                  }
                  if let closeSplit {
                    Button("Close purchase", role: .destructive) { closeSplit(purchase) }
                  }
                }
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

  private func sectionHeader(_ section: LedgerBrowseSection) -> some View {
    let title = Self.sectionTitle(section.id, formatter: formatter)
    // A one-entry day's total repeats the row's amount, so it is left out.
    let totals =
      section.entries.count > 1
      ? Self.describe(section.totals, formatter: formatter, omittingZero: true) : ""
    return HStack(alignment: .firstTextBaseline) {
      Text(title)
        .font(LedgerTheme.Typeface.captionEmphasis)
        .foregroundStyle(LedgerTheme.inkSecondary)
      Spacer()
      if !totals.isEmpty {
        Text(totals)
          .font(LedgerTheme.Typeface.caption)
          .monospacedDigit()
          .foregroundStyle(LedgerTheme.inkTertiary)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(totals.isEmpty ? title : "\(title), \(totals)")
  }

  /// One entry in two short lines: what it was for, then where the money moved and how it is
  /// tagged; the signed amount on the right. The kind, time and markers are spoken, and shown in
  /// the inspector, so the row stays one glance tall.
  private func row(_ entry: LedgerBrowseEntry) -> some View {
    let category = entry.categoryID.flatMap { categoryNames[$0] }
    let account = entry.accountIDs.compactMap { accountNames[$0] }.joined(separator: " → ")
    let title = category ?? entry.kind.rawValue.capitalized
    let signed = Self.signedAmount(entry)
    let amountText = formatter.parts(signed.amount, sign: signed.sign).text
    let time = String(format: "%02d:%02d", entry.occurredAt.hour, entry.occurredAt.minute)
    // Say the kind in words when the title is a category, so income and expense never rely on
    // colour, sign or category names alone.
    let kind = category == nil ? nil : entry.kind.rawValue.capitalized
    let spokenDetail = [kind, account.isEmpty ? nil : account, time].compactMap { $0 }
      .joined(separator: " · ")
    let markers = entry.indicators.map(Self.indicatorLabel).joined(separator: ", ")
    let tagNamesSorted = entry.tagIDs.compactMap { tagNames[$0] }.sorted {
      $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }
    let tagLine = tagNamesSorted.map { "#\($0)" }.joined(separator: " ")
    let shownDetail = ([account.isEmpty ? nil : account, entry.note] + tagNamesSorted.map { "#\($0)" })
      .compactMap { $0 }.joined(separator: " · ")
    return HStack(alignment: .center, spacing: LedgerTheme.Space.m) {
      LedgerIconTile(
        .symbol(LedgerCategorySymbol.name(for: category, kind: entry.kind)),
        swatch: LedgerTheme.swatch(for: title))
      VStack(alignment: .leading, spacing: LedgerTheme.Space.xxs) {
        Text(title)
          .font(LedgerTheme.Typeface.body)
          .foregroundStyle(LedgerTheme.ink)
          .strikethrough(entry.lifecycle == .tombstoned)
          .lineLimit(1)
        if !shownDetail.isEmpty {
          Text(shownDetail)
            .font(LedgerTheme.Typeface.caption)
            .foregroundStyle(LedgerTheme.inkSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }
      .layoutPriority(1)
      Spacer(minLength: LedgerTheme.Space.s)
      HStack(spacing: LedgerTheme.Space.xs) {
        ForEach(entry.indicators, id: \.self) { indicator in
          Image(systemName: Self.indicatorSymbol(indicator))
            .font(LedgerTheme.Typeface.caption)
            .foregroundStyle(LedgerTheme.inkTertiary)
            .help(Self.indicatorLabel(indicator))
        }
      }
      .accessibilityHidden(true)
      VStack(alignment: .trailing, spacing: LedgerTheme.Space.xxs) {
        MoneyText(signed.amount, size: .row, sign: signed.sign)
        if let conversion = entry.conversion {
          Text(conversion)
            .font(LedgerTheme.Typeface.caption)
            .monospacedDigit()
            .foregroundStyle(LedgerTheme.inkTertiary)
            .lineLimit(1)
        }
      }
      .fixedSize()
    }
    .frame(minHeight: LedgerTheme.Metrics.tableRow - 4)
    .padding(.vertical, LedgerTheme.Space.xxs)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      [
        title, spokenDetail.isEmpty ? nil : spokenDetail, amountText, entry.conversion, entry.note,
        tagLine.isEmpty ? nil : "tags \(tagLine)", markers.isEmpty ? nil : markers,
      ].compactMap { $0 }
        .joined(separator: ", "))
  }

  /// Money in shows "+", spending "−"; transfers and adjustments move money without a sign.
  static func signedAmount(_ entry: LedgerBrowseEntry) -> (
    amount: CurrencyAmount, sign: LedgerDisplayFormatter.SignStyle
  ) {
    switch entry.kind {
    case .income:
      return (entry.amount, .always)
    case .expense:
      guard let zero = try? ExactDecimal("0"),
        let negative = try? zero.subtracting(entry.amount.amount),
        let amount = try? CurrencyAmount(unitCode: entry.amount.unitCode, amount: negative)
      else { return (entry.amount, .never) }
      return (amount, .always)
    case .transfer, .adjustment:
      return (entry.amount, .never)
    }
  }

  /// "Monday, 2 November 2026" for a day, "November 2026" for a month.
  static func sectionTitle(_ id: String, formatter: LedgerDisplayFormatter) -> String {
    if id == "total" { return "All transactions" }
    let parts = id.split(separator: "-").compactMap { Int($0) }
    if parts.count == 3, let date = try? SourceLocalDate(year: parts[0], month: parts[1], day: parts[2]) {
      return formatter.date(date, style: .full)
    }
    if parts.count == 2, let date = try? SourceLocalDate(year: parts[0], month: parts[1], day: 1) {
      return formatter.monthTitle(date)
    }
    return id
  }

  private func splitRow(_ purchase: LedgerSplitPurchase) -> some View {
    DisclosureGroup {
      ForEach(purchase.lines, id: \.id) { line in
        let category = categoryNames[line.categoryID] ?? "Category"
        let amount = formatter.parts(line.amount).text
        let text = "\(line.description ?? "Split line"), \(category), \(amount)"
        HStack {
          Text(line.description ?? "Split line").font(LedgerTheme.Typeface.body)
            .foregroundStyle(LedgerTheme.ink)
          Text(category).font(LedgerTheme.Typeface.caption).foregroundStyle(LedgerTheme.inkSecondary)
          Spacer(minLength: LedgerTheme.Space.s)
          MoneyText(line.amount, size: .row)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
      }
    } label: {
      HStack {
        Text("Split purchase").font(LedgerTheme.Typeface.body).foregroundStyle(LedgerTheme.ink)
        Text("\(purchase.lines.count) categories").font(LedgerTheme.Typeface.caption)
          .foregroundStyle(LedgerTheme.inkSecondary)
        Spacer(minLength: LedgerTheme.Space.s)
        MoneyText(purchase.parentAmount, size: .row)
      }
    }
    .accessibilityLabel(
      "Split purchase, \(formatter.parts(purchase.parentAmount).text), \(purchase.lines.count) categories"
    )
  }

  @ViewBuilder private var pager: some View {
    if let page, page.pageCount > 1 {
      HStack(spacing: LedgerTheme.Space.s) {
        Button("Previous page") { pageIndex = max(0, page.pageIndex - 1) }
          .disabled(page.pageIndex == 0)
          .keyboardShortcut("[", modifiers: .command)
        Text("Page \(page.pageIndex + 1) of \(page.pageCount)")
          .font(LedgerTheme.Typeface.caption)
          .monospacedDigit()
          .foregroundStyle(LedgerTheme.inkSecondary)
          .accessibilityLabel("Page \(page.pageIndex + 1) of \(page.pageCount)")
        Button("Next page") { pageIndex = min(page.pageCount - 1, page.pageIndex + 1) }
          .disabled(page.pageIndex + 1 >= page.pageCount)
          .keyboardShortcut("]", modifiers: .command)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, LedgerTheme.Space.l)
      .padding(.vertical, LedgerTheme.Space.s)
    }
  }

  // MARK: Bulk edit (#168)

  /// Shown while more than one entry is selected: how many, a way to select every entry this
  /// view matches (all pages), and the bulk actions. They need editing, like every change.
  @ViewBuilder private var bulkBar: some View {
    if selectedIDs.count > 1 {
      HStack(spacing: LedgerTheme.Space.m) {
        Text("\(selectedIDs.count) selected")
          .font(LedgerTheme.Typeface.captionEmphasis)
          .foregroundStyle(LedgerTheme.ink)
        if selectedIDs.count < matchCount {
          Button("Select All \(matchCount)") { selectAllMatching() }
            .buttonStyle(LedgerSecondaryButtonStyle())
            .accessibilityLabel("Select all \(matchCount) entries this view shows")
            .help("Select every entry this view shows, on every page")
        }
        Spacer(minLength: LedgerTheme.Space.s)
        if let bulkEdit {
          let ids = Array(selectedIDs)
          Menu("Set Category") {
            Button("No Category") { bulkEdit(.category(nil), ids) }
            Divider()
            ForEach(bulkCategories, id: \.id) { category in
              Button(CategoryPresentation.label(category, in: categories)) {
                bulkEdit(.category(category.id), ids)
              }
            }
          }
          .fixedSize()
          .accessibilityLabel("Set the category of the selected entries")
          Menu("Add Tag") {
            ForEach(tags.filter { $0.lifecycle == .active }, id: \.id) { tag in
              Button(tag.name) { bulkEdit(.addTag(tag.id), ids) }
            }
          }
          .fixedSize()
          .disabled(!tags.contains { $0.lifecycle == .active })
          .accessibilityLabel("Add a tag to the selected entries")
          Menu("Remove Tag") {
            ForEach(tags, id: \.id) { tag in
              Button(tag.name) { bulkEdit(.removeTag(tag.id), ids) }
            }
          }
          .fixedSize()
          .disabled(tags.isEmpty)
          .accessibilityLabel("Remove a tag from the selected entries")
        } else {
          Text("Begin editing to change them.")
            .font(LedgerTheme.Typeface.caption)
            .foregroundStyle(LedgerTheme.inkTertiary)
        }
        Button("Clear Selection") { selectedIDs = [] }
          .buttonStyle(LedgerSecondaryButtonStyle())
      }
      .padding(.horizontal, LedgerTheme.Space.l)
      .padding(.vertical, LedgerTheme.Space.s)
      .background(LedgerTheme.recessed)
      .overlay(alignment: .top) { Divider().overlay(LedgerTheme.hairline) }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Bulk actions for \(selectedIDs.count) selected entries")
    }
  }

  private var bulkCategories: [LedgerCategory] {
    categories.filter { $0.lifecycle == .active && !$0.hidden }
      .sorted { CategoryPresentation.label($0, in: categories) < CategoryPresentation.label($1, in: categories) }
  }

  /// Every entry this view matches, on every page (⌘A selects the rows on this page).
  private func selectAllMatching() {
    selectedIDs = Set(browser.matches(mode: mode, filter: filter).map { browser.entries[$0].id })
  }

  // MARK: State

  /// New snapshot (after an edit, copy or close): re-sort and keep the selection on screen.
  /// Small ledgers index at once. Large ones index off the main thread, so the window stays
  /// responsive; the previous index stays on screen (or "Loading ledger…" the first time).
  private func rebuild() {
    let transactions = transactions
    let hiddenIDs = hiddenIDs
    let accountNames = accountNames
    let categoryNames = categoryNames
    let revisionTags = revisionTags
    let tagNames = tagNames
    let build: @Sendable () -> LedgerBrowser = {
      LedgerBrowser(
        transactions: transactions, hiding: hiddenIDs, accountNames: accountNames,
        categoryNames: categoryNames, revisionTags: revisionTags, tagNames: tagNames)
    }
    buildGeneration += 1
    guard transactions.count > Self.backgroundIndexThreshold else {
      apply(build())
      return
    }
    let generation = buildGeneration
    Task {
      let built = await Task.detached(priority: .userInitiated) { build() }.value
      guard generation == buildGeneration else { return }
      apply(built)
    }
  }

  static let backgroundIndexThreshold = 5_000

  private func apply(_ built: LedgerBrowser) {
    browser = built
    isLoading = false
    if calendarMonth == nil, let newest = browser.entries.first?.occurredAt.date {
      calendarMonth = (newest.year, newest.month)
    }
    refresh(keepingSelection: true)
  }

  private func refresh(keepingSelection: Bool) {
    let matches = browser.matches(mode: mode, filter: filter)
    matchCount = matches.count
    // Several selected: keep only what this view still shows, so the bulk bar never counts
    // entries a filter has hidden.
    if selectedIDs.count > 1 {
      let shown = Set(matches.map { browser.entries[$0].id })
      selectedIDs.formIntersection(shown)
    }
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

  /// "In ₹78,000.00 · Out ₹4,862.50" per currency, in the display formatter's style. With
  /// `omittingZero`, a side with no money is left out ("Out ₹450.00" for a day of spending).
  static func describe(
    _ totals: [LedgerBrowseTotal], formatter: LedgerDisplayFormatter, omittingZero: Bool = false
  ) -> String {
    totals.compactMap { total -> String? in
      func text(_ value: ExactDecimal?) -> String? {
        guard let value, let amount = try? CurrencyAmount(unitCode: total.unitCode, amount: value)
        else { return "unavailable" }
        if omittingZero, !value.isPositive, !value.isNegative { return nil }
        return formatter.parts(amount, sign: .never).text
      }
      let sides = [text(total.income).map { "In \($0)" }, text(total.expense).map { "Out \($0)" }]
        .compactMap { $0 }
      return sides.isEmpty ? nil : sides.joined(separator: " · ")
    }
    .joined(separator: "; ")
  }

  static func describe(_ totals: [LedgerBrowseTotal], hidingAmounts: Bool) -> String {
    let money = LedgerDisplayFormatter(
      locale: Locale(identifier: "en_US_POSIX"), hidesAmounts: hidingAmounts)
    return totals.map { total in
      let income = total.income.map { money.plain($0) } ?? "unavailable"
      let expense = total.expense.map { money.plain($0) } ?? "unavailable"
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

/// What the ledger's entry area shows. Pure, so each operational state is testable.
package enum LedgerBrowseContent: Equatable {
  case loading, emptyLedger, noNotes, noMatches, entries

  package static func state(
    isLoading: Bool, entryCount: Int, matchCount: Int?, filterActive: Bool,
    mode: LedgerBrowseMode
  ) -> LedgerBrowseContent {
    if isLoading { return .loading }
    if entryCount == 0 && !filterActive { return .emptyLedger }
    if let matchCount, matchCount == 0, filterActive || mode == .note {
      return mode == .note && !filterActive ? .noNotes : .noMatches
    }
    return .entries
  }
}
