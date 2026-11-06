import CryptoKit
import Foundation
import LedgerCore
import LedgerStore
import SwiftUI

/// Pure rules behind the Tags & Memos screen, kept apart from SwiftUI so tests can check them.
enum AnnotationPresentation {
  enum Section: String, CaseIterable, Identifiable {
    case tags = "Tags"
    case templates = "Templates"
    case memos = "Memos"

    var id: Self { self }
  }

  /// Active tags first, then retired ones; each group by name, ignoring case.
  static func sortedTags(_ tags: [LedgerTag]) -> [LedgerTag] {
    tags.sorted {
      if ($0.lifecycle == .active) != ($1.lifecycle == .active) { return $0.lifecycle == .active }
      let order = $0.name.localizedCaseInsensitiveCompare($1.name)
      return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
    }
  }

  /// How many live transactions carry each tag, counted on their current revision only.
  static func usageCounts(
    transactions: [LedgerTransactionSnapshot], revisionTags: [String: LedgerTagLinks]
  ) -> [String: Int] {
    var counts: [String: Int] = [:]
    for transaction in transactions where transaction.currentRevision.lifecycle == .active {
      for tagID in revisionTags[transaction.currentRevision.id]?.tagIDs ?? [] {
        counts[tagID, default: 0] += 1
      }
    }
    return counts
  }

  static func activeTemplates(_ templates: [LedgerTransactionTemplate])
    -> [LedgerTransactionTemplate]
  {
    templates.filter { $0.lifecycle == .active }.sorted {
      let order = $0.name.localizedCaseInsensitiveCompare($1.name)
      return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
    }
  }

  /// Newest day first. Deleted memos are not shown.
  static func activeMemos(_ memos: [LedgerMemo]) -> [LedgerMemo] {
    memos.filter { $0.lifecycle == .active }.sorted {
      $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date
    }
  }

  static func dateLabel(_ date: SourceLocalDate) -> String {
    String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
  }

  /// The civil day a person picked, read in their calendar. Stored memos never shift with time
  /// zones because only year, month and day are kept.
  static func localDate(from date: Date, calendar: Calendar = .current) throws -> SourceLocalDate {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    guard let year = parts.year, let month = parts.month, let day = parts.day else {
      throw LedgerAnnotationError.invalidBody
    }
    return try SourceLocalDate(year: year, month: month, day: day)
  }

  static func pickerDate(for date: SourceLocalDate, calendar: Calendar = .current) -> Date {
    calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day))
      ?? Date()
  }

  static func firstLine(_ body: String) -> String {
    body.split(whereSeparator: \.isNewline).first.map(String.init) ?? body
  }

  static func templateSummary(
    _ template: LedgerTransactionTemplate, accounts: [LedgerAccount],
    categories: [LedgerCategory]
  ) -> String {
    let name: (String?) -> String? = { id in accounts.first { $0.id == id }?.name }
    let amount = "\(template.amount.amount.rawLiteral) \(template.amount.unitCode)"
    let from = name(template.accountID) ?? "Unknown account"
    if template.kind == .transfer {
      let to = name(template.counterAccountID) ?? "Unknown account"
      return "Transfer · \(amount) · \(from) → \(to)"
    }
    let category = template.categoryID.flatMap { id in categories.first { $0.id == id }?.name }
    return [template.kind.rawValue.capitalized, amount, from, category]
      .compactMap { $0 }.joined(separator: " · ")
  }

  /// Tags a person can tick: every active tag, plus retired tags the item already carries so
  /// they can be removed.
  static func selectableTags(_ tags: [LedgerTag], keeping selected: Set<String>) -> [LedgerTag] {
    sortedTags(tags.filter { $0.lifecycle == .active || selected.contains($0.id) })
  }

  static func tagNames(_ links: LedgerTagLinks, in tags: [LedgerTag]) -> [String] {
    links.tagIDs.compactMap { id in tags.first { $0.id == id }?.name }
      .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }

  /// A fresh random local key for a new Mac-native row.
  static func generatedKey(_ kind: String) -> String {
    SHA256.hash(data: Data("ledger-atlas/\(kind)/\(UUID().uuidString)".utf8))
      .map { String(format: "%02x", $0) }.joined()
  }
}

struct TagsView: View {
  let state: LedgerSession.State
  let tags: [LedgerTag]
  let templates: [LedgerTransactionTemplate]
  let memos: [LedgerMemo]
  let transactions: [LedgerTransactionSnapshot]
  let revisionTags: [String: LedgerTagLinks]
  let accounts: [LedgerAccount]
  let categories: [LedgerCategory]
  let isEditing: Bool
  let lastFailure: String?
  let beginEditing: () -> Void
  let createTag: (LedgerTag) -> Void
  let updateTag: (LedgerTag) -> Void
  let saveTemplate: (LedgerTransactionTemplate) -> Void
  let useTemplate: (_ templateID: String, _ submissionID: String) -> Void
  let saveMemo: (LedgerMemo) -> Void
  let open: () -> Void

  @State private var section: AnnotationPresentation.Section = .tags
  @State private var showingTagForm = false
  @State private var renamingTag: LedgerTag?
  @State private var showingTemplateForm = false
  @State private var editingTemplate: LedgerTransactionTemplate?
  @State private var pendingUse: PendingTemplateUse?
  @State private var showingMemoForm = false
  @State private var editingMemo: LedgerMemo?

  private struct PendingTemplateUse: Identifiable {
    let template: LedgerTransactionTemplate
    let submissionID = UUID().uuidString
    var id: String { submissionID }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      switch state {
      case .loaded:
        Picker("Show", selection: $section) {
          ForEach(AnnotationPresentation.Section.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 320)
        .padding(.horizontal, LedgerTheme.Space.l)
        .padding(.vertical, LedgerTheme.Space.m)
        .accessibilityLabel("Show tags, templates or memos")
        switch section {
        case .tags: tagList
        case .templates: templateList
        case .memos: memoList
        }
      default:
        LedgerSessionEmptyState(
          state: state, title: "No tags", systemImage: "number",
          message: "Choose a ledger to view its tags and memos.", failure: lastFailure, open: open)
      }
      if case .loaded = state {
        LedgerActionBar {
          if isEditing {
            switch section {
            case .tags:
              Button("New tag") { showingTagForm = true }.buttonStyle(LedgerPrimaryButtonStyle())
            case .templates:
              Button("New template") { showingTemplateForm = true }
                .buttonStyle(LedgerPrimaryButtonStyle())
                .disabled(accounts.allSatisfy { $0.lifecycle != .active })
            case .memos:
              Button("New memo") { showingMemoForm = true }.buttonStyle(LedgerPrimaryButtonStyle())
            }
          } else {
            Button("Begin editing", action: beginEditing)
              .buttonStyle(LedgerSecondaryButtonStyle())
              .accessibilityLabel("Begin editing tags, templates and memos")
          }
          if let lastFailure { LedgerStatusLine(failure: lastFailure) }
        }
      } else if let lastFailure {
        LedgerActionBar { LedgerStatusLine(failure: lastFailure) }
      }
    }
    .ledgerCanvas()
    .navigationTitle("Tags & Memos")
    .sheet(isPresented: $showingTagForm) {
      TagNameForm(title: "New tag", initialName: "") { name in
        guard let origin = try? LedgerOrigin.macNative(),
          let id = try? StableLedgerID.tag(
            origin: origin, localKey: AnnotationPresentation.generatedKey("tag")),
          let tag = try? LedgerTag(id: id, name: name, origin: origin)
        else { return }
        createTag(tag)
      }
    }
    .sheet(isPresented: isPresent($renamingTag)) {
      if let tag = renamingTag {
        TagNameForm(title: "Rename tag", initialName: tag.name) { name in
          guard let renamed = try? tag.renamed(name) else { return }
          updateTag(renamed)
        }
      }
    }
    .sheet(isPresented: $showingTemplateForm) {
      TemplateForm(template: nil, accounts: accounts, categories: categories, tags: tags) {
        saveTemplate($0)
      }
    }
    .sheet(isPresented: isPresent($editingTemplate)) {
      if let template = editingTemplate {
        TemplateForm(template: template, accounts: accounts, categories: categories, tags: tags) {
          saveTemplate($0)
        }
      }
    }
    .sheet(isPresented: $showingMemoForm) {
      MemoForm(memo: nil) { saveMemo($0) }
    }
    .sheet(isPresented: isPresent($editingMemo)) {
      if let memo = editingMemo {
        MemoForm(memo: memo) { saveMemo($0) }
      }
    }
    .confirmationDialog(
      "Record this template as a transaction dated today?",
      isPresented: Binding(get: { pendingUse != nil }, set: { if !$0 { pendingUse = nil } }),
      presenting: pendingUse
    ) { use in
      Button("Record “\(use.template.name)”") {
        useTemplate(use.template.id, use.submissionID)
        pendingUse = nil
      }
      Button("Cancel", role: .cancel) { pendingUse = nil }
    } message: { use in
      Text(AnnotationPresentation.templateSummary(use.template, accounts: accounts, categories: categories))
    }
  }

  private func isPresent<Item>(_ item: Binding<Item?>) -> Binding<Bool> {
    Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
  }

  @ViewBuilder private var tagList: some View {
    let ordered = AnnotationPresentation.sortedTags(tags)
    if ordered.isEmpty {
      LedgerEmptyState(
        "No tags", systemImage: "number",
        message: isEditing ? "Create a tag to label transactions across categories." : "Begin editing to create tags.")
    } else {
      let counts = AnnotationPresentation.usageCounts(transactions: transactions, revisionTags: revisionTags)
      List(ordered, id: \.id) { tag in
        let count = counts[tag.id, default: 0]
        let detail = "\(count) transaction\(count == 1 ? "" : "s")\(tag.lifecycle == .active ? "" : " · retired")"
        HStack(spacing: LedgerTheme.Space.m) {
          LedgerIconTile(.symbol("number"), swatch: LedgerTheme.swatch(for: tag.name))
          VStack(alignment: .leading, spacing: LedgerTheme.Space.xxs) {
            Text(tag.name)
              .font(LedgerTheme.Typeface.bodyEmphasis)
              .foregroundStyle(tag.lifecycle == .active ? LedgerTheme.ink : LedgerTheme.inkTertiary)
            Text(detail).font(LedgerTheme.Typeface.caption).foregroundStyle(LedgerTheme.inkTertiary)
          }
          Spacer(minLength: LedgerTheme.Space.s)
          if tag.lifecycle != .active { LedgerBadge("Retired", systemImage: "archivebox") }
          if tag.lifecycle == .active {
            Menu("Actions") {
              Button("Rename tag") { renamingTag = tag }
              Button("Retire tag") { if let retired = try? tag.tombstoned() { updateTag(retired) } }
            }
            .disabled(!isEditing)
            .accessibilityLabel("Actions for \(tag.name)")
          }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(tag.name), \(detail)")
      }
    }
  }

  @ViewBuilder private var templateList: some View {
    let active = AnnotationPresentation.activeTemplates(templates)
    if active.isEmpty {
      LedgerEmptyState(
        "No templates", systemImage: "doc.on.doc",
        message: isEditing ? "Save a transaction you repeat, then record it in one step." : "Begin editing to create templates.")
    } else {
      List(active, id: \.id) { template in
        let summary = AnnotationPresentation.templateSummary(template, accounts: accounts, categories: categories)
        let tagNames = AnnotationPresentation.tagNames(template.tags, in: tags)
        HStack(spacing: LedgerTheme.Space.m) {
          LedgerIconTile(.symbol("doc.on.doc"), swatch: LedgerTheme.swatch(for: template.name))
          VStack(alignment: .leading, spacing: LedgerTheme.Space.xxs) {
            Text(template.name).font(LedgerTheme.Typeface.bodyEmphasis).foregroundStyle(LedgerTheme.ink)
            Text(summary).font(LedgerTheme.Typeface.caption).foregroundStyle(LedgerTheme.inkTertiary)
            if !tagNames.isEmpty {
              Text(tagNames.map { "#\($0)" }.joined(separator: " "))
                .font(LedgerTheme.Typeface.caption)
                .foregroundStyle(LedgerTheme.accent)
            }
          }
          Spacer(minLength: LedgerTheme.Space.s)
          Button("Use") { pendingUse = PendingTemplateUse(template: template) }
            .buttonStyle(LedgerSecondaryButtonStyle())
            .disabled(!isEditing)
            .accessibilityLabel("Record \(template.name) as a transaction today")
          Menu("Actions") {
            Button("Edit template") { editingTemplate = template }
            Button("Delete template") {
              if let retired = try? template.tombstoned() { saveTemplate(retired) }
            }
          }
          .disabled(!isEditing)
          .accessibilityLabel("Actions for \(template.name)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(template.name), \(summary)")
      }
    }
  }

  @ViewBuilder private var memoList: some View {
    let active = AnnotationPresentation.activeMemos(memos)
    if active.isEmpty {
      LedgerEmptyState(
        "No memos", systemImage: "note.text",
        message: isEditing ? "Write a note for a day, such as a trip or a bill you expect." : "Begin editing to write memos.")
    } else {
      List(active, id: \.id) { memo in
        let date = AnnotationPresentation.dateLabel(memo.date)
        HStack(alignment: .top, spacing: LedgerTheme.Space.m) {
          LedgerIconTile(.symbol("note.text"), swatch: LedgerTheme.swatch(for: date))
          VStack(alignment: .leading, spacing: LedgerTheme.Space.xxs) {
            Text(date)
              .font(LedgerTheme.Typeface.captionEmphasis)
              .foregroundStyle(LedgerTheme.inkSecondary)
              .monospacedDigit()
            Text(memo.body).font(LedgerTheme.Typeface.body).foregroundStyle(LedgerTheme.ink).lineLimit(3)
          }
          Spacer(minLength: LedgerTheme.Space.s)
          Menu("Actions") {
            Button("Edit memo") { editingMemo = memo }
            Button("Delete memo") { if let deleted = try? memo.tombstoned() { saveMemo(deleted) } }
          }
          .disabled(!isEditing)
          .accessibilityLabel("Actions for memo on \(date)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Memo on \(date): \(AnnotationPresentation.firstLine(memo.body))")
      }
    }
  }
}

struct TagNameForm: View {
  let title: String
  let fieldLabel: String
  let isValid: (String) -> Bool
  let onSave: (String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name: String

  init(
    title: String, initialName: String, fieldLabel: String = "Tag name",
    isValid: @escaping (String) -> Bool = LedgerTag.isValidName,
    onSave: @escaping (String) -> Void
  ) {
    self.title = title
    self.fieldLabel = fieldLabel
    self.isValid = isValid
    self.onSave = onSave
    _name = State(initialValue: initialName)
  }

  private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    Form {
      Text(title).font(LedgerTheme.Typeface.cardTitle).foregroundStyle(LedgerTheme.ink)
      TextField(fieldLabel, text: $name)
      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
        Spacer()
        Button("Save") {
          onSave(trimmed)
          dismiss()
        }
        .disabled(!isValid(trimmed))
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 360)
  }
}

/// Ticks tags on or off for one transaction. Retired tags it already carries stay listed so
/// they can be removed; new links go to active tags only.
struct TagPickerForm: View {
  let tags: [LedgerTag]
  let onSave: (LedgerTagLinks) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var selected: Set<String>
  private let original: Set<String>

  init(tags: [LedgerTag], selected: LedgerTagLinks, onSave: @escaping (LedgerTagLinks) -> Void) {
    self.tags = tags
    self.onSave = onSave
    original = Set(selected.tagIDs)
    _selected = State(initialValue: Set(selected.tagIDs))
  }

  var body: some View {
    Form {
      Text("Tags").font(LedgerTheme.Typeface.cardTitle).foregroundStyle(LedgerTheme.ink)
      let choices = AnnotationPresentation.selectableTags(tags, keeping: original)
      if choices.isEmpty {
        Text("No tags yet. Create tags under Tags & Memos.").font(LedgerTheme.Typeface.secondary).foregroundStyle(LedgerTheme.inkSecondary)
      }
      ForEach(choices, id: \.id) { tag in
        Toggle(
          tag.lifecycle == .active ? tag.name : "\(tag.name) (retired)",
          isOn: Binding(
            get: { selected.contains(tag.id) },
            set: { if $0 { selected.insert(tag.id) } else { selected.remove(tag.id) } }))
      }
      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
        Spacer()
        Button("Save") {
          guard let links = try? LedgerTagLinks(Array(selected)) else { return }
          onSave(links)
          dismiss()
        }
        .disabled(selected == original)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 360)
  }
}

struct TemplateForm: View {
  let template: LedgerTransactionTemplate?
  let accounts: [LedgerAccount]
  let categories: [LedgerCategory]
  let tags: [LedgerTag]
  let onSave: (LedgerTransactionTemplate) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var kind: LedgerTransactionKind
  @State private var accountID: String?
  @State private var counterAccountID: String?
  @State private var categoryID: String?
  @State private var amount: String
  @State private var note: String
  @State private var selectedTags: Set<String>

  init(
    template: LedgerTransactionTemplate?, accounts: [LedgerAccount], categories: [LedgerCategory],
    tags: [LedgerTag], onSave: @escaping (LedgerTransactionTemplate) -> Void
  ) {
    self.template = template
    self.accounts = accounts
    self.categories = categories
    self.tags = tags
    self.onSave = onSave
    _name = State(initialValue: template?.name ?? "")
    _kind = State(initialValue: template?.kind ?? .expense)
    _accountID = State(
      initialValue: template?.accountID ?? accounts.first { $0.lifecycle == .active }?.id)
    _counterAccountID = State(initialValue: template?.counterAccountID)
    _categoryID = State(initialValue: template?.categoryID)
    _amount = State(initialValue: template?.amount.amount.rawLiteral ?? "")
    _note = State(initialValue: template?.note ?? "")
    _selectedTags = State(initialValue: Set(template?.tags.tagIDs ?? []))
  }

  private var activeAccounts: [LedgerAccount] {
    accounts.filter { $0.lifecycle == .active || $0.id == accountID || $0.id == counterAccountID }
  }

  private var eligibleCategories: [LedgerCategory] {
    categories.filter {
      ($0.lifecycle == .active && !$0.hidden && $0.kind.accepts(kind)) || $0.id == categoryID
    }
    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  var body: some View {
    Form {
      Text(template == nil ? "New template" : "Edit template").font(LedgerTheme.Typeface.cardTitle).foregroundStyle(LedgerTheme.ink)
      TextField("Template name", text: $name)
      if template == nil {
        Picker("Kind", selection: $kind) {
          Text("Expense").tag(LedgerTransactionKind.expense)
          Text("Income").tag(LedgerTransactionKind.income)
          Text("Transfer").tag(LedgerTransactionKind.transfer)
        }
        Picker(kind == .transfer ? "From account" : "Account", selection: $accountID) {
          ForEach(activeAccounts, id: \.id) { Text($0.name).tag(Optional($0.id)) }
        }
        if kind == .transfer {
          Picker("To account", selection: $counterAccountID) {
            Text("Choose…").tag(String?.none)
            ForEach(activeAccounts.filter { $0.id != accountID }, id: \.id) {
              Text($0.name).tag(Optional($0.id))
            }
          }
        }
      }
      if kind != .transfer {
        Picker("Category", selection: $categoryID) {
          Text("None").tag(String?.none)
          ForEach(eligibleCategories, id: \.id) { Text($0.name).tag(Optional($0.id)) }
        }
      }
      TextField("Amount (\(currencyUnit ?? "—"))", text: $amount)
      TextField("Note", text: $note)
      let choices = AnnotationPresentation.selectableTags(tags, keeping: selectedTags)
      if !choices.isEmpty {
        Section("Tags") {
          ForEach(choices, id: \.id) { tag in
            Toggle(
              tag.lifecycle == .active ? tag.name : "\(tag.name) (retired)",
              isOn: Binding(
                get: { selectedTags.contains(tag.id) },
                set: { if $0 { selectedTags.insert(tag.id) } else { selectedTags.remove(tag.id) } }))
          }
        }
      }
      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
        Spacer()
        Button("Save") {
          guard let built = build() else { return }
          onSave(built)
          dismiss()
        }
        .disabled(build() == nil)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 440)
    .onChange(of: kind) {
      if kind == .transfer { categoryID = nil } else { counterAccountID = nil }
      if let categoryID, !eligibleCategories.contains(where: { $0.id == categoryID }) {
        self.categoryID = nil
      }
    }
  }

  private var currencyUnit: String? {
    template?.amount.unitCode ?? accounts.first { $0.id == accountID }?.currencyUnit
  }

  private func build() -> LedgerTransactionTemplate? {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty, let currencyUnit,
      let value = try? ExactDecimal(amount.trimmingCharacters(in: .whitespaces)),
      let money = try? CurrencyAmount(unitCode: currencyUnit, amount: value),
      let links = try? LedgerTagLinks(Array(selectedTags))
    else { return nil }
    let noteValue: String? = trimmedNote.isEmpty ? nil : trimmedNote
    let category = kind == .transfer ? nil : categoryID
    if let template {
      return try? template.edited(
        name: trimmedName, categoryID: .some(category), amount: money, note: .some(noteValue),
        tags: links)
    }
    guard let accountID, let origin = try? LedgerOrigin.macNative(),
      let id = try? StableLedgerID.transactionTemplate(
        origin: origin, localKey: AnnotationPresentation.generatedKey("template"))
    else { return nil }
    return try? LedgerTransactionTemplate(
      id: id, name: trimmedName, kind: kind, categoryID: category, amount: money,
      note: noteValue, accountID: accountID,
      counterAccountID: kind == .transfer ? counterAccountID : nil, tags: links, origin: origin)
  }
}

struct MemoForm: View {
  let memo: LedgerMemo?
  let onSave: (LedgerMemo) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var day: Date
  @State private var text: String

  init(memo: LedgerMemo?, onSave: @escaping (LedgerMemo) -> Void) {
    self.memo = memo
    self.onSave = onSave
    _day = State(initialValue: memo.map { AnnotationPresentation.pickerDate(for: $0.date) } ?? Date())
    _text = State(initialValue: memo?.body ?? "")
  }

  var body: some View {
    Form {
      Text(memo == nil ? "New memo" : "Edit memo").font(LedgerTheme.Typeface.cardTitle).foregroundStyle(LedgerTheme.ink)
      DatePicker("Day", selection: $day, displayedComponents: .date)
      TextEditor(text: $text)
        .frame(minHeight: 120)
        .accessibilityLabel("Memo text")
      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
        Spacer()
        Button("Save") {
          guard let built = build() else { return }
          onSave(built)
          dismiss()
        }
        .disabled(build() == nil)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 440)
  }

  private func build() -> LedgerMemo? {
    guard let date = try? AnnotationPresentation.localDate(from: day) else { return nil }
    if let memo { return try? memo.edited(body: text, date: date) }
    guard let origin = try? LedgerOrigin.macNative(),
      let id = try? StableLedgerID.memo(
        origin: origin, localKey: AnnotationPresentation.generatedKey("memo"))
    else { return nil }
    return try? LedgerMemo(id: id, body: text, date: date, origin: origin)
  }
}
