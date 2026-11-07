import AppKit
import CryptoKit
import LedgerCore
import LedgerStore
import SwiftUI
import UniformTypeIdentifiers

struct NativeTransactionForm: View {
  /// The account the last entry used, so the next form starts there (#169).
  static let lastAccountKey = "LedgerAtlas.entry.lastAccountID"

  let accounts: [LedgerAccount]
  let categories: [LedgerCategory]
  let intent: LedgerIntentRequest?
  let tags: [LedgerTag]
  /// The open ledger's entries, searched for an earlier entry with the memo typed (#169).
  let entries: [LedgerTransactionSnapshot]
  /// (submission ID, amount literal, kind, account ID, category ID, note, tags), answering nil
  /// when the entry was saved or the message to show when it was not. The submission ID is
  /// fixed for one entry, so a repeated Save is the same submission, not a new entry.
  let onSave:
    (String, String, LedgerTransactionKind, String, String?, String?, LedgerTagLinks) -> String?
  @Environment(\.dismiss) private var dismiss
  @Environment(\.ledgerFormatter) private var formatter
  @AppStorage(Self.lastAccountKey) private var lastAccountID = ""
  @State private var isSaving = false
  /// What this entry holds; a save that succeeds starts a fresh one.
  @State private var entry: NativeEntryFields
  @State private var kind: LedgerTransactionKind = .expense
  @State private var accountID = ""
  /// The account a new entry starts on: the last one saved, so a suggestion can be taken back.
  @State private var defaultAccountID = ""
  @FocusState private var amountFocused: Bool

  init(
    accounts: [LedgerAccount], categories: [LedgerCategory], intent: LedgerIntentRequest? = nil,
    tags: [LedgerTag] = [], entries: [LedgerTransactionSnapshot] = [],
    onSave: @escaping (
      String, String, LedgerTransactionKind, String, String?, String?, LedgerTagLinks
    ) -> String?
  ) {
    self.accounts = accounts
    self.categories = categories
    self.intent = intent
    self.tags = tags
    self.entries = entries
    self.onSave = onSave
    var entry = NativeEntryFields()
    entry.amount = intent?.amountLiteral ?? ""
    entry.note = intent?.note ?? ""
    _entry = State(initialValue: entry)
    _kind = State(initialValue: intent?.kind == .addIncome ? .income : .expense)
  }

  private var availableCategories: [LedgerCategory] {
    categories.filter {
      $0.lifecycle == .active && !$0.hidden && $0.kind.accepts(kind)
    }.sorted { $0.name < $1.name }
  }

  private var activeAccounts: [LedgerAccount] { accounts.filter { $0.lifecycle == .active } }

  /// "Account and category from 3 Oct", while the form still shows what was suggested.
  private var suggestionText: String? {
    guard let suggestion = entry.suggestion else { return nil }
    let account =
      suggestion.accountID != nil && suggestion.accountID == accountID && !entry.accountChosen
    let category =
      suggestion.categoryID != nil && suggestion.categoryID == entry.categoryID
      && !entry.categoryChosen
    let what: String
    switch (account, category) {
    case (true, true): what = "Account and category"
    case (true, false): what = "Account"
    case (false, true): what = "Category"
    case (false, false): return nil
    }
    return "\(what) suggested from an entry on \(formatter.date(suggestion.fromDay))"
  }

  var body: some View {
    Form {
      if activeAccounts.isEmpty {
        ContentUnavailableView(
          "No open accounts", systemImage: "rectangle.stack",
          description: Text(
            "Create an account, or reopen a closed one, before entering a transaction."))
      } else {
        TextField("Amount", text: $entry.amount)
          .focused($amountFocused)
        Picker("Type", selection: $kind) {
          Text("Expense").tag(LedgerTransactionKind.expense)
          Text("Income").tag(LedgerTransactionKind.income)
        }
        Picker(
          "Account",
          selection: Binding(
            get: { accountID }, set: { accountID = $0; entry.accountChosen = true })
        ) {
          ForEach(activeAccounts, id: \.id) { account in
            Text("\(account.name) (\(account.currencyUnit))").tag(account.id)
          }
        }
        Picker(
          "Category",
          selection: Binding(
            get: { entry.categoryID }, set: { entry.categoryID = $0; entry.categoryChosen = true })
        ) {
          Text("No category").tag(String?.none)
          ForEach(availableCategories, id: \.id) { category in
            Text(CategoryPresentation.label(category, in: categories)).tag(Optional(category.id))
          }
        }
        TextField("Note (optional)", text: $entry.note)
        if let suggestionText {
          Text(suggestionText)
            .font(LedgerTheme.Typeface.caption)
            .foregroundStyle(LedgerTheme.inkSecondary)
            .accessibilityLabel(suggestionText)
        }
        let activeTags = AnnotationPresentation.selectableTags(tags, keeping: [])
        if !activeTags.isEmpty {
          Section("Tags") {
            ForEach(activeTags, id: \.id) { tag in
              Toggle(
                tag.name,
                isOn: Binding(
                  get: { entry.selectedTags.contains(tag.id) },
                  set: {
                    if $0 { entry.selectedTags.insert(tag.id) } else { entry.selectedTags.remove(tag.id) }
                  }))
            }
          }
        }
        if let error = entry.saveError {
          Text(error)
            .font(LedgerTheme.Typeface.caption)
            .foregroundStyle(LedgerTheme.negative)
            .fixedSize(horizontal: false, vertical: true)
        } else if entry.savedCount > 0 {
          Text(
            entry.savedCount == 1
              ? "Saved. Enter the next one." : "Saved \(entry.savedCount). Enter the next one.")
            .font(LedgerTheme.Typeface.caption)
            .foregroundStyle(LedgerTheme.inkSecondary)
        }
        HStack {
          // Escape closes; Return saves and starts the next entry with the account kept.
          Button(entry.savedCount == 0 ? "Cancel" : "Done", role: .cancel) { dismiss() }
            .keyboardShortcut(.cancelAction)
          Spacer()
          Button("Save") { save() }
            .keyboardShortcut(.defaultAction)
            .disabled(
              isSaving || entry.amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || accountID.isEmpty)
        }
      }
    }
    .padding(20)
    .frame(width: 460)
    .onAppear {
      if accountID.isEmpty {
        accountID =
          activeAccounts.first(where: { $0.id == lastAccountID })?.id
          ?? activeAccounts.first?.id ?? ""
      }
      defaultAccountID = accountID
      amountFocused = true
    }
    .onChange(of: kind) { _, _ in
      if let categoryID = entry.categoryID,
        !availableCategories.contains(where: { $0.id == categoryID })
      {
        entry.categoryID = nil
        // The person's pick no longer applies, so a suggestion may fill the empty field.
        entry.categoryChosen = false
      }
    }
    // Looked up a moment after typing stops, off the main thread: on a 100,000-entry ledger
    // the scan takes a noticeable fraction of a second.
    .task(id: SuggestionKey(note: entry.note, kind: kind)) {
      await suggest()
    }
    .accessibilityElement(children: .contain)
  }

  private struct SuggestionKey: Equatable {
    let note: String
    let kind: LedgerTransactionKind
  }

  private func suggest() async {
    let memo = entry.note
    let kind = kind
    guard !LedgerEntrySuggestion.normalizedMemo(memo).isEmpty, !entries.isEmpty else {
      withdrawSuggestion()
      return
    }
    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
    let (accounts, categories, entries) = (accounts, categories, entries)
    let found = await Task.detached(priority: .userInitiated) {
      LedgerEntrySuggestion.suggestion(
        forMemo: memo, kind: kind, accounts: accounts, categories: categories,
        transactions: entries)
    }.value
    guard !Task.isCancelled, memo == entry.note, kind == self.kind else { return }
    withdrawSuggestion()
    guard let found else { return }
    entry.suggestion = found
    // Fill only what the person hasn't chosen; nothing is saved until they save.
    if !entry.accountChosen, let id = found.accountID,
      activeAccounts.contains(where: { $0.id == id })
    {
      accountID = id
    }
    if !entry.categoryChosen, let id = found.categoryID,
      availableCategories.contains(where: { $0.id == id })
    {
      entry.categoryID = id
    }
  }

  /// Takes back what the last suggestion filled once the memo no longer matches it, so a
  /// field never keeps a suggested value without the words that say where it came from.
  /// Anything the person picked themselves stays.
  private func withdrawSuggestion() {
    guard let old = entry.suggestion else { return }
    entry.suggestion = nil
    if !entry.accountChosen, old.accountID != nil, accountID == old.accountID {
      accountID = defaultAccountID
    }
    if !entry.categoryChosen, old.categoryID != nil, entry.categoryID == old.categoryID {
      entry.categoryID = nil
    }
  }

  private func save() {
    guard !isSaving else { return }
    let cleanAmount = entry.amount.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanAmount.isEmpty, !accountID.isEmpty else { return }
    isSaving = true
    defer { isSaving = false }
    let cleanNote = entry.note.trimmingCharacters(in: .whitespacesAndNewlines)
    let links = (try? LedgerTagLinks(Array(entry.selectedTags))) ?? .empty
    let failure = onSave(
      entry.submissionID, cleanAmount, kind, accountID, entry.categoryID,
      cleanNote.isEmpty ? nil : cleanNote, links)
    entry.finishSave(failure: failure)
    guard failure == nil else { return }
    lastAccountID = accountID
    defaultAccountID = accountID
    amountFocused = true
  }
}

/// What one entry in the form holds (#169), and what a save keeps of it.
struct NativeEntryFields: Equatable {
  var submissionID = UUID().uuidString
  var amount = ""
  var note = ""
  var categoryID: String?
  var selectedTags: Set<String> = []
  /// Set once the person picks an account or category themselves; a suggestion never
  /// overrides a choice.
  var accountChosen = false
  var categoryChosen = false
  var suggestion: LedgerEntrySuggestion?
  /// Entries saved since the form opened, for "Saved. Enter the next one."
  var savedCount = 0
  /// Why the last Save did not save, shown under the form until the next Save.
  var saveError: String?

  /// After `onSave` answers. Saved (nil): a fresh entry with a new submission ID, so the next
  /// Save is a new entry; the form keeps the kind and account. Not saved: every field and the
  /// same submission ID stay, so nothing typed is lost and Save again is the same submission.
  mutating func finishSave(failure: String?) {
    if let failure {
      saveError = failure
      return
    }
    self = NativeEntryFields(savedCount: savedCount + 1)
  }
}

struct SplitLineInput: Identifiable {
  let id: Int
  var amount = ""
  var categoryID = ""
  var description = ""
  /// Set when editing an existing purchase, so each line keeps its identity.
  var lineID: String?
}

struct SplitPurchaseForm: View {
  let accounts: [LedgerAccount]
  let categories: [LedgerCategory]
  let onSave: (LedgerSplitDraft) -> Void
  /// When set, the form edits this purchase: same lines, same purchase ID.
  var existing: LedgerSplitPurchase?
  @Environment(\.dismiss) private var dismiss
  @State private var parentAmount = ""
  @State private var accountID = ""
  @State private var note = ""
  @State private var lines = [SplitLineInput(id: 0), SplitLineInput(id: 1), SplitLineInput(id: 2)]

  private var availableCategories: [LedgerCategory] {
    let current = Set(existing?.lines.map(\.categoryID) ?? [])
    return categories.filter {
      ($0.lifecycle == .active && !$0.hidden && $0.kind == .expense) || current.contains($0.id)
    }
    .sorted { $0.name < $1.name }
  }

  var body: some View {
    Form {
      if existing != nil {
        Text("Edit split purchase").font(.headline)
      }
      if accounts.isEmpty || availableCategories.count < 2 {
        ContentUnavailableView(
          "Split purchase needs setup", systemImage: "square.split.2x1",
          description: Text("Create an account and at least two active expense categories first."))
      } else {
        TextField("Purchase total", text: $parentAmount)
        Picker("Account", selection: $accountID) {
          ForEach(accounts.filter { $0.lifecycle == .active }, id: \.id) { account in
            Text("\(account.name) (\(account.currencyUnit))").tag(account.id)
          }
        }
        Section("Categories") {
          ForEach($lines) { $line in
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Text("Line \(line.id + 1)").font(.headline)
                Spacer()
                TextField("Amount", text: $line.amount)
                  .frame(width: 110)
              }
              Picker("Category", selection: $line.categoryID) {
                Text("Choose category…").tag("")
                ForEach(availableCategories, id: \.id) { category in
                  Text(CategoryPresentation.label(category, in: categories)).tag(category.id)
                }
              }
              TextField("Description (optional)", text: $line.description)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Split line \(line.id + 1)")
          }
        }
        TextField("Purchase note (optional)", text: $note)
        if let mismatch = sumMismatch {
          Text(mismatch).font(.caption).foregroundStyle(.orange).accessibilityLabel(mismatch)
        }
        HStack {
          Button("Cancel", role: .cancel) { dismiss() }
          Spacer()
          Button(existing == nil ? "Save split purchase" : "Save changes") { save() }
            .disabled(parentAmount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || accountID.isEmpty)
        }
      }
    }
    .padding(20)
    .frame(width: 560)
    .onAppear {
      if let existing, accountID.isEmpty {
        accountID = existing.accountID
        parentAmount = existing.parentAmount.amount.rawLiteral
        note = existing.note ?? ""
        lines = existing.lines.enumerated().map { index, line in
          SplitLineInput(
            id: index, amount: line.amount.amount.rawLiteral, categoryID: line.categoryID,
            description: line.description ?? "", lineID: line.id)
        }
      }
      if accountID.isEmpty { accountID = accounts.first(where: { $0.lifecycle == .active })?.id ?? "" }
    }
    .accessibilityElement(children: .contain)
  }

  /// Says how far the lines are from the total, so a save that would be refused is explained.
  private var sumMismatch: String? {
    guard let total = try? ExactDecimal(parentAmount.trimmingCharacters(in: .whitespaces))
    else { return nil }
    var sum = try? ExactDecimal("0")
    for input in lines {
      let raw = input.amount.trimmingCharacters(in: .whitespaces)
      guard !raw.isEmpty else { continue }
      guard let value = try? ExactDecimal(raw) else { return nil }
      sum = try? sum?.adding(value)
    }
    guard let sum, sum != total else { return nil }
    return "Lines add up to \(sum.rawLiteral); the total is \(total.rawLiteral)."
  }

  private func save() {
    if let existing {
      saveEdit(of: existing)
      return
    }
    let cleanParent = parentAmount.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let origin = try? LedgerOrigin.macNative(),
      let localKey = Self.digest("split:\(UUID().uuidString)"),
      let purchaseID = try? StableLedgerID.transaction(origin: origin, localKey: localKey),
      let account = accounts.first(where: { $0.id == accountID }),
      let total = try? CurrencyAmount(unitCode: account.currencyUnit, amount: ExactDecimal(cleanParent)),
      let occurredAt = try? LedgerJourney.nativeTemporal(
        for: UTCInstant(epochMilliseconds: UTCInstant.currentEpochMilliseconds()))
    else { return }
    var builtLines: [LedgerSplitLine] = []
    for input in lines where !input.amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let cleanAmount = input.amount.trimmingCharacters(in: .whitespacesAndNewlines)
      let cleanDescription = input.description.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !input.categoryID.isEmpty,
        let amount = try? CurrencyAmount(
          unitCode: account.currencyUnit, amount: ExactDecimal(cleanAmount)),
        let lineID = try? StableLedgerID.splitLine(
          origin: origin, localKey: Self.digest("\(purchaseID):\(input.id)") ?? localKey),
        let line = try? LedgerSplitLine(
          id: lineID, amount: amount, categoryID: input.categoryID,
          description: cleanDescription.isEmpty ? nil : cleanDescription, displayOrder: input.id)
      else { return }
      builtLines.append(line)
    }
    guard builtLines.count >= 2,
      let draft = try? LedgerSplitDraft(
        id: purchaseID, accountID: accountID, parentAmount: total, lines: builtLines,
        occurredAt: occurredAt, note: cleanNote.isEmpty ? nil : cleanNote, origin: origin)
    else { return }
    onSave(draft)
    dismiss()
  }

  /// Keeps the purchase ID, line IDs, origin and date; every line stays (removing lines is not
  /// supported, so a blank amount fails the save instead of dropping the line).
  private func saveEdit(of purchase: LedgerSplitPurchase) {
    let cleanParent = parentAmount.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let account = accounts.first(where: { $0.id == accountID }),
      let total = try? CurrencyAmount(
        unitCode: account.currencyUnit, amount: ExactDecimal(cleanParent))
    else { return }
    var builtLines: [LedgerSplitLine] = []
    for (index, input) in lines.enumerated() {
      let cleanDescription = input.description.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let lineID = input.lineID, !input.categoryID.isEmpty,
        let amount = try? CurrencyAmount(
          unitCode: account.currencyUnit,
          amount: ExactDecimal(input.amount.trimmingCharacters(in: .whitespacesAndNewlines))),
        let line = try? LedgerSplitLine(
          id: lineID, amount: amount, categoryID: input.categoryID,
          description: cleanDescription.isEmpty ? nil : cleanDescription, displayOrder: index)
      else { return }
      builtLines.append(line)
    }
    guard
      let draft = try? LedgerSplitDraft(
        id: purchase.id, accountID: accountID, parentAmount: total, lines: builtLines,
        occurredAt: purchase.occurredAt, note: cleanNote.isEmpty ? nil : cleanNote,
        origin: purchase.origin)
    else { return }
    onSave(draft)
    dismiss()
  }

  private static func digest(_ value: String) -> String? {
    let result = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    return CanonicalIdentifier.isValid(result) ? result : nil
  }
}
