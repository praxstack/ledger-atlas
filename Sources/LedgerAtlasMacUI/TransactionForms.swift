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
  let onSave: (String, LedgerTransactionKind, String, String?, String?) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var amount = ""
  @State private var kind: LedgerTransactionKind = .expense
  @State private var accountID = ""
  @State private var categoryID: String?
  @State private var note = ""

  init(
    accounts: [LedgerAccount], categories: [LedgerCategory], intent: LedgerIntentRequest? = nil,
    onSave: @escaping (String, LedgerTransactionKind, String, String?, String?) -> Void
  ) {
    self.accounts = accounts
    self.categories = categories
    self.intent = intent
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
        HStack {
          Button("Cancel", role: .cancel) { dismiss() }
          Spacer()
          Button("Save") { save() }
            .disabled(amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || accountID.isEmpty)
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
    let cleanAmount = amount.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
    onSave(cleanAmount, kind, accountID, categoryID, cleanNote.isEmpty ? nil : cleanNote)
    dismiss()
  }
}

struct SplitLineInput: Identifiable {
  let id: Int
  var amount = ""
  var categoryID = ""
  var description = ""
}

struct SplitPurchaseForm: View {
  let accounts: [LedgerAccount]
  let categories: [LedgerCategory]
  let onSave: (LedgerSplitDraft) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var parentAmount = ""
  @State private var accountID = ""
  @State private var note = ""
  @State private var lines = [SplitLineInput(id: 0), SplitLineInput(id: 1), SplitLineInput(id: 2)]

  private var availableCategories: [LedgerCategory] {
    categories.filter { $0.lifecycle == .active && !$0.hidden && $0.kind == .expense }
      .sorted { $0.name < $1.name }
  }

  var body: some View {
    Form {
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
        HStack {
          Button("Cancel", role: .cancel) { dismiss() }
          Spacer()
          Button("Save split purchase") { save() }
            .disabled(parentAmount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || accountID.isEmpty)
        }
      }
    }
    .padding(20)
    .frame(width: 560)
    .onAppear {
      if accountID.isEmpty { accountID = accounts.first(where: { $0.lifecycle == .active })?.id ?? "" }
    }
    .accessibilityElement(children: .contain)
  }

  private func save() {
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

  private static func digest(_ value: String) -> String? {
    let result = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    return CanonicalIdentifier.isValid(result) ? result : nil
  }
}
