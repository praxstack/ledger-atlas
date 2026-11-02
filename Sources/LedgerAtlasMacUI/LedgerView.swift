import AppKit
import CryptoKit
import LedgerCore
import LedgerStore
import SwiftUI
import UniformTypeIdentifiers

struct LedgerView: View {
  private enum ViewMode: String, CaseIterable, Identifiable {
    case daily, calendar, monthly, total, note

    var id: Self { self }

    var title: String {
      switch self {
      case .daily: "Daily"
      case .calendar: "Calendar"
      case .monthly: "Monthly"
      case .total: "Total"
      case .note: "Note"
      }
    }
  }

  let state: LedgerSession.State
  let rows: [LedgerJourney.SurfaceRow]
  let isEditing: Bool
  let accounts: [LedgerAccount]
  let categories: [LedgerCategory]
  let transactions: [LedgerTransactionSnapshot]
  let splitPurchases: [LedgerSplitPurchase]
  let splitTransactionIDs: Set<String>
  let splitNotice: String?
  let intentRequest: LedgerIntentRequest?
  let consumeIntent: () -> Void
  let open: () -> Void
  let lifecycleMessage: String?
  let lastFailure: String?
  let beginEditing: () -> Void
  let saveAmount: (String, String) -> Void
  let tombstone: (String) -> Void
  let copy: (String) -> Void
  let addMacTransaction: (String) -> Void
  let createTransaction: (String, LedgerTransactionKind, String, String?, String?) -> Void
  let createSplit: (LedgerSplitDraft) -> Void
  @State private var selectedID: String?
  @State private var amountLiteral = ""
  @State private var macAmountLiteral = ""
  @State private var showingTransactionForm = false
  @State private var showingSplitForm = false
  @State private var viewMode: ViewMode = .daily
  @State private var page = 0

  private let pageSize = 100

  private var transactionByID: [String: LedgerTransactionSnapshot] {
    Dictionary(uniqueKeysWithValues: transactions.map { ($0.id, $0) })
  }

  private var filteredRows: [LedgerJourney.SurfaceRow] {
    let candidates = rows.filter { !splitTransactionIDs.contains($0.id) }
    guard viewMode == .note else { return candidates }
    return candidates.filter { transactionByID[$0.id]?.currentRevision.draft.note != nil }
  }

  private var pagedRows: [LedgerJourney.SurfaceRow] {
    let start = min(page * pageSize, filteredRows.count)
    return Array(filteredRows.dropFirst(start).prefix(pageSize))
  }

  private var groupedRows: [(String, [LedgerJourney.SurfaceRow])] {
    let grouped = Dictionary(grouping: pagedRows) { row in
      guard let transaction = transactionByID[row.id] else { return "Undated" }
      let date = transaction.currentRevision.draft.occurredAt.localDateTime.date
      switch viewMode {
      case .monthly:
        return String(format: "%04d-%02d", date.year, date.month)
      case .total:
        return "All transactions"
      case .daily, .calendar, .note:
        return String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
      }
    }
    return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
  }

  var body: some View {
    Group {
      if !rows.isEmpty {
        VStack(alignment: .leading, spacing: 12) {
          Picker("Ledger view", selection: $viewMode) {
            ForEach(ViewMode.allCases) { mode in
              Text(mode.title).tag(mode)
            }
          }
          .pickerStyle(.segmented)
          .padding(.horizontal, 16)
          .accessibilityLabel("Ledger view")
          .onChange(of: viewMode) { _, _ in page = 0 }
          if let splitNotice {
            Text(splitNotice)
              .font(.caption)
              .foregroundStyle(.orange)
              .padding(.horizontal, 16)
              .accessibilityLabel(splitNotice)
          }
          List(selection: $selectedID) {
            ForEach(groupedRows, id: \.0) { title, sectionRows in
              Section(title) {
                ForEach(sectionRows) { row in
                  VStack(alignment: .leading, spacing: 4) {
                    Text(row.title)
                    Text(row.detail).font(.caption).foregroundStyle(.secondary)
                  }
                  .tag(row.id)
                  .contextMenu {
                    Button("Copy transaction") { copy(row.id) }
                    Button("Close transaction", role: .destructive) { tombstone(row.id) }
                  }
                }
              }
            }
            ForEach(splitPurchases, id: \.id) { purchase in
              DisclosureGroup {
                ForEach(purchase.lines, id: \.id) { line in
                  VStack(alignment: .leading, spacing: 2) {
                    Text(line.description ?? "Split line")
                    Text("Category \(line.categoryID) · \(line.amount.amount.rawLiteral) \(line.amount.unitCode)")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  .accessibilityElement(children: .combine)
                  .accessibilityLabel(
                    "\(line.description ?? "Split line"), category \(line.categoryID), \(line.amount.amount.rawLiteral) \(line.amount.unitCode)"
                  )
                }
              } label: {
                VStack(alignment: .leading, spacing: 4) {
                  Text("Split purchase")
                  Text("\(purchase.parentAmount.amount.rawLiteral) \(purchase.parentAmount.unitCode) · \(purchase.lines.count) categories")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              .accessibilityLabel(
                "Split purchase, \(purchase.parentAmount.amount.rawLiteral) \(purchase.parentAmount.unitCode), \(purchase.lines.count) categories"
              )
            }
          }
          if filteredRows.count > pageSize {
            HStack {
              Button("Previous page") { page = max(0, page - 1) }
                .disabled(page == 0)
              Text("Page \(page + 1) of \(max(1, (filteredRows.count + pageSize - 1) / pageSize))")
                .font(.caption.monospaced())
                .accessibilityLabel("Page \(page + 1)")
              Button("Next page") {
                page = min((filteredRows.count - 1) / pageSize, page + 1)
              }
              .disabled((page + 1) * pageSize >= filteredRows.count)
            }
            .padding(.horizontal, 16)
          }
        if let lifecycleMessage {
          Text(lifecycleMessage)
            .foregroundStyle(.secondary)
            .accessibilityLabel(lifecycleMessage)
            .padding(.horizontal, 16)
        }
        if let lastFailure {
          Text(lastFailure)
            .foregroundStyle(.red)
            .accessibilityLabel(lastFailure)
            .padding(.horizontal, 16)
        }
        if isEditing {
          HStack {
            Button("New transaction") { showingTransactionForm = true }
              .accessibilityLabel("New income or expense")
            Button("New split purchase") { showingSplitForm = true }
              .accessibilityLabel("New split purchase")
          }
          .padding(.horizontal, 16)
          HStack {
            TextField("Amount", text: $amountLiteral)
            Button("Save") {
              guard let selectedID, !amountLiteral.isEmpty else { return }
              saveAmount(selectedID, amountLiteral)
            }
            .accessibilityLabel("Save amount")
          }
          .padding(.horizontal, 16)
          HStack {
            Button("Copy selected") {
              guard let selectedID else { return }
              copy(selectedID)
            }
            .disabled(selectedID == nil)
            Button("Close selected", role: .destructive) {
              guard let selectedID else { return }
              tombstone(selectedID)
            }
            .disabled(selectedID == nil)
          }
          .padding(.horizontal, 16)
          HStack {
            TextField("Mac amount", text: $macAmountLiteral)
            Button("Add Mac transaction") {
              guard !macAmountLiteral.isEmpty else { return }
              addMacTransaction(macAmountLiteral)
            }
            .accessibilityLabel("Add Mac transaction")
          }
          .padding(.horizontal, 16)
          .padding(.bottom, 12)
        } else {
          Button("Begin editing", action: beginEditing)
            .accessibilityLabel("Begin editing")
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        }
        .navigationTitle("Ledger")
      } else {
        switch state {
        case .noLedger:
          openPrompt(
            title: "Open a ledger", icon: "folder",
            description: "Choose a Ledger Atlas ledger to view its native transactions.",
            buttonTitle: "Open Ledger…", guidance: .noLedger,
            failure: lifecycleMessage ?? lastFailure)
        case .loading:
          ProgressView("Opening ledger…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
          openPrompt(
            title: "Ledger unavailable", icon: "exclamationmark.triangle",
            description: "This ledger could not be opened safely.",
            buttonTitle: "Choose another ledger…", guidance: .unavailable,
            failure: lifecycleMessage ?? lastFailure)
        case .loaded(let snapshot)
        where snapshot.transactions.isEmpty && snapshot.undisplayedImportedEventCount > 0:
          ContentUnavailableView(
            "Imported data is preserved", systemImage: "archivebox",
            description: Text(
              "This ledger has imported records that are not yet displayable in the native ledger."))
        case .loaded(let snapshot) where snapshot.transactions.isEmpty:
          VStack(spacing: 12) {
            ContentUnavailableView(
              "No transactions", systemImage: "list.bullet",
              description: Text(
                lifecycleMessage ?? "This native ledger has no transactions yet."))
            if isEditing {
              HStack {
                Button("New transaction") { showingTransactionForm = true }
                  .accessibilityLabel("New income or expense")
                Button("New split purchase") { showingSplitForm = true }
                  .accessibilityLabel("New split purchase")
              }
            } else {
              Button("Begin editing", action: beginEditing)
                .accessibilityLabel("Begin editing")
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let snapshot):
          List {
            ForEach(snapshot.transactions) { transaction in
              VStack(alignment: .leading, spacing: 4) {
                Text(transaction.title)
                Text(transaction.detail)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
          .navigationTitle("Ledger")
        }
      }
    }
    .sheet(isPresented: $showingTransactionForm) {
      NativeTransactionForm(
        accounts: accounts, categories: categories, intent: intentRequest,
        onSave: { amount, kind, accountID, categoryID, note in
          createTransaction(amount, kind, accountID, categoryID, note)
          if intentRequest != nil { consumeIntent() }
        })
    }
    .sheet(isPresented: $showingSplitForm) {
      SplitPurchaseForm(accounts: accounts, categories: categories, onSave: createSplit)
    }
    .onAppear { presentIntentIfNeeded() }
    .onChange(of: intentRequest) { _, _ in presentIntentIfNeeded() }
  }

  private func presentIntentIfNeeded() {
    guard let intentRequest, !showingTransactionForm else { return }
    guard intentRequest.kind == .addExpense || intentRequest.kind == .addIncome else { return }
    showingTransactionForm = true
  }

  private func openPrompt(
    title: String, icon: String, description: String, buttonTitle: String,
    guidance: LedgerLifecycleGuidance? = nil, failure: String? = nil
  )
    -> some View
  {
    VStack(spacing: 12) {
      Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary)
      Text(title).font(.title2.bold())
      Text(description).foregroundStyle(.secondary)
      if let guidance { LedgerLifecycleGuidanceView(guidance: guidance, failure: failure) }
      Button(buttonTitle, action: open)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(32)
  }
}
