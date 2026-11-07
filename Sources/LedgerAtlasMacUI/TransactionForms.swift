import AppKit
import CryptoKit
import LedgerCore
import LedgerStore
import SwiftUI
import UniformTypeIdentifiers

struct NativeTransactionForm: View {
  let accounts: [LedgerAccount]
  let categories: [LedgerCategory]
  let intent: LedgerIntentRequest?
  let tags: [LedgerTag]
  /// (submission ID, amount literal, kind, account ID, category ID, note, tags).  The submission
  /// ID is fixed for the life of the form, so a repeated Save is the same submission, not a new
  /// entry.
  let onSave:
    (String, String, LedgerTransactionKind, String, String?, String?, LedgerTagLinks) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var submissionID = UUID().uuidString
  @State private var isSaving = false
  @State private var amount = ""
  @State private var kind: LedgerTransactionKind = .expense
  @State private var accountID = ""
  @State private var categoryID: String?
  @State private var note = ""
  @State private var selectedTags: Set<String> = []

  init(
    accounts: [LedgerAccount], categories: [LedgerCategory], intent: LedgerIntentRequest? = nil,
    tags: [LedgerTag] = [],
    onSave: @escaping (
      String, String, LedgerTransactionKind, String, String?, String?, LedgerTagLinks
    ) -> Void
  ) {
    self.accounts = accounts
    self.categories = categories
    self.intent = intent
    self.tags = tags
    self.onSave = onSave
    _amount = State(initialValue: intent?.amountLiteral ?? "")
    _kind = State(initialValue: intent?.kind == .addIncome ? .income : .expense)
    _note = State(initialValue: intent?.note ?? "")
  }

  private var availableCategories: [LedgerCategory] {
    categories.filter {
      $0.lifecycle == .active && !$0.hidden && $0.kind.accepts(kind)
    }.sorted { $0.name < $1.name }
  }

  var body: some View {
    Form {
      if accounts.isEmpty {
        ContentUnavailableView(
          "No accounts", systemImage: "rectangle.stack",
          description: Text("Create an account before entering a transaction."))
      } else {
        TextField("Amount", text: $amount)
        Picker("Type", selection: $kind) {
          Text("Expense").tag(LedgerTransactionKind.expense)
          Text("Income").tag(LedgerTransactionKind.income)
        }
        Picker("Account", selection: $accountID) {
          ForEach(accounts.filter { $0.lifecycle == .active }, id: \.id) { account in
            Text("\(account.name) (\(account.currencyUnit))").tag(account.id)
          }
        }
        Picker("Category", selection: $categoryID) {
          Text("No category").tag(String?.none)
          ForEach(availableCategories, id: \.id) { category in
            Text(CategoryPresentation.label(category, in: categories)).tag(Optional(category.id))
          }
        }
        TextField("Note (optional)", text: $note)
        let activeTags = AnnotationPresentation.selectableTags(tags, keeping: [])
        if !activeTags.isEmpty {
          Section("Tags") {
            ForEach(activeTags, id: \.id) { tag in
              Toggle(
                tag.name,
                isOn: Binding(
                  get: { selectedTags.contains(tag.id) },
                  set: { if $0 { selectedTags.insert(tag.id) } else { selectedTags.remove(tag.id) } }))
            }
          }
        }
        HStack {
          Button("Cancel", role: .cancel) { dismiss() }
          Spacer()
          Button("Save") { save() }
            .disabled(
              isSaving || amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || accountID.isEmpty)
        }
      }
    }
    .padding(20)
    .frame(width: 460)
    .onAppear {
      if accountID.isEmpty { accountID = accounts.first(where: { $0.lifecycle == .active })?.id ?? "" }
    }
    .onChange(of: kind) { _, _ in
      if let categoryID, !availableCategories.contains(where: { $0.id == categoryID }) {
        self.categoryID = nil
      }
    }
    .accessibilityElement(children: .contain)
  }

  private func save() {
    guard !isSaving else { return }
    isSaving = true
    let cleanAmount = amount.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
    let links = (try? LedgerTagLinks(Array(selectedTags))) ?? .empty
    onSave(
      submissionID, cleanAmount, kind, accountID, categoryID, cleanNote.isEmpty ? nil : cleanNote,
      links)
    dismiss()
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
          Text(mismatch).font(LedgerTheme.Typeface.caption).foregroundStyle(LedgerTheme.warning)
            .accessibilityLabel(mismatch)
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
