import AppKit
import CryptoKit
import LedgerCore
import LedgerStore
import SwiftUI
import UniformTypeIdentifiers

struct LedgerView: View {
  let state: LedgerSession.State
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
  /// Starts a Money Manager import; offered wherever the ledger is empty or missing.
  var importBackup: (() -> Void)? = nil
  let lifecycleMessage: String?
  let lastFailure: String?
  let beginEditing: () -> Void
  let saveAmount: (String, String) -> Void
  let tombstone: (String) -> Void
  let copy: (String) -> Void
  let addMacTransaction: (String) -> Void
  let createTransaction:
    (String, String, LedgerTransactionKind, String, String?, String?, LedgerTagLinks) -> Void
  let createSplit: (LedgerSplitDraft) -> Void
  var tags: [LedgerTag] = []
  var revisionTags: [String: LedgerTagLinks] = [:]
  /// (transaction ID, new tags).
  var saveTags: ((String, LedgerTagLinks) -> Void)?
  /// (transaction ID, template name).
  var saveAsTemplate: ((String, String) -> Void)?
  var editSplit: ((LedgerSplitDraft) -> Void)?
  var closeSplit: ((String) -> Void)?
  @State private var editingSplit: LedgerSplitPurchase?
  @State private var selectedID: String?
  @State private var taggingID: String?
  @State private var templatingID: String?
  @State private var amountLiteral = ""
  @State private var macAmountLiteral = ""
  @State private var showingTransactionForm = false
  @State private var showingSplitForm = false

  var body: some View {
    Group {
      if !transactions.isEmpty {
        VStack(alignment: .leading, spacing: 12) {
          if let splitNotice {
            Text(splitNotice)
              .font(.caption)
              .foregroundStyle(.orange)
              .padding(.horizontal, 16)
              .accessibilityLabel(splitNotice)
          }
          LedgerBrowseList(
            transactions: transactions, hiddenIDs: splitTransactionIDs, accounts: accounts,
            categories: categories, splitPurchases: splitPurchases, selectedID: $selectedID,
            copy: copy, tombstone: tombstone, tags: tags, revisionTags: revisionTags,
            editTags: isEditing && saveTags != nil ? { (id: String) in taggingID = id } : nil,
            saveAsTemplate: isEditing && saveAsTemplate != nil
              ? { (id: String) in templatingID = id } : nil,
            editSplit: isEditing && editSplit != nil
              ? { (purchase: LedgerSplitPurchase) in editingSplit = purchase } : nil,
            closeSplit: isEditing && closeSplit != nil
              ? { (purchase: LedgerSplitPurchase) in closeSplit?(purchase.id) } : nil)
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
        editBar
          .padding(.horizontal, LedgerTheme.Space.l)
          .padding(.vertical, LedgerTheme.Space.s)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(LedgerTheme.recessed)
          .overlay(alignment: .top) { Divider().overlay(LedgerTheme.hairline) }
        }
        .navigationTitle("Transactions")
      } else {
        switch state {
        case .noLedger:
          openPrompt(
            title: "Open a ledger", icon: "folder",
            description: "Choose a Ledger Atlas ledger, or import a Money Manager backup.",
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
            if let importBackup {
              Button(LedgerAtlasRootView.importBackupActionTitle, action: importBackup)
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
        accounts: accounts, categories: categories, intent: intentRequest, tags: tags,
        entries: transactions,
        onSave: { submissionID, amount, kind, accountID, categoryID, note, links in
          createTransaction(submissionID, amount, kind, accountID, categoryID, note, links)
          if intentRequest != nil { consumeIntent() }
        })
    }
    .sheet(isPresented: $showingSplitForm) {
      SplitPurchaseForm(accounts: accounts, categories: categories, onSave: createSplit)
    }
    .sheet(
      isPresented: Binding(get: { editingSplit != nil }, set: { if !$0 { editingSplit = nil } })
    ) {
      if let purchase = editingSplit {
        SplitPurchaseForm(
          accounts: accounts, categories: categories,
          onSave: { draft in editSplit?(draft) }, existing: purchase)
      }
    }
    .sheet(
      isPresented: Binding(get: { taggingID != nil }, set: { if !$0 { taggingID = nil } })
    ) {
      if let id = taggingID,
        let revisionID = transactions.first(where: { $0.id == id })?.currentRevision.id
      {
        TagPickerForm(tags: tags, selected: revisionTags[revisionID] ?? .empty) { links in
          saveTags?(id, links)
        }
      }
    }
    .sheet(
      isPresented: Binding(get: { templatingID != nil }, set: { if !$0 { templatingID = nil } })
    ) {
      if let id = templatingID {
        TagNameForm(
          title: "Save as template", initialName: "", fieldLabel: "Template name",
          isValid: {
            !$0.isEmpty && $0.utf8.count <= LedgerTransactionTemplate.maximumNameBytes
          }
        ) { name in
          saveAsTemplate?(id, name)
        }
      }
    }
    .onChange(of: selectedID) { _, id in
      // Start an amount edit from the selected entry's current amount.
      guard let id,
        let amount = transactions.first(where: { $0.id == id })?.currentRevision.draft.effects
          .first?.amount.amount.rawLiteral
      else { return }
      amountLiteral = amount
    }
    .onAppear { presentIntentIfNeeded() }
    .onChange(of: intentRequest) { _, _ in presentIntentIfNeeded() }
    .onChange(of: accounts.count) { _, _ in presentIntentIfNeeded() }
  }

  /// The actions under the list: new entries, then what to do with the selected one.
  @ViewBuilder private var editBar: some View {
    if isEditing {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: LedgerTheme.Space.s) {
          createButtons
          Divider().frame(height: 20)
          selectionActions
          Spacer(minLength: 0)
          quickAdd
        }
        VStack(alignment: .leading, spacing: LedgerTheme.Space.s) {
          HStack(spacing: LedgerTheme.Space.s) { createButtons }
          HStack(spacing: LedgerTheme.Space.s) { selectionActions }
          quickAdd
        }
      }
    } else {
      HStack(spacing: LedgerTheme.Space.s) {
        Button("Begin editing", action: beginEditing)
          .buttonStyle(LedgerSecondaryButtonStyle())
          .accessibilityLabel("Begin editing")
        Text("The ledger is read-only until you begin editing.")
          .font(LedgerTheme.Typeface.caption)
          .foregroundStyle(LedgerTheme.inkTertiary)
      }
    }
  }

  @ViewBuilder private var createButtons: some View {
    Button {
      showingTransactionForm = true
    } label: {
      Label("New Transaction", systemImage: "plus")
    }
    .buttonStyle(LedgerPrimaryButtonStyle())
    .accessibilityLabel("New income or expense")
    Button("New Split…") { showingSplitForm = true }
      .buttonStyle(LedgerSecondaryButtonStyle())
      .accessibilityLabel("New split purchase")
  }

  @ViewBuilder private var selectionActions: some View {
    TextField("Amount", text: $amountLiteral)
      .textFieldStyle(.roundedBorder)
      .frame(width: 110)
      .disabled(selectedID == nil)
      .accessibilityLabel("Corrected amount for the selected transaction")
    Button("Save") {
      guard let selectedID, !amountLiteral.isEmpty else { return }
      saveAmount(selectedID, amountLiteral)
    }
    .buttonStyle(LedgerSecondaryButtonStyle())
    .disabled(selectedID == nil)
    .accessibilityLabel("Save amount")
    Menu("Selected") {
      Button("Copy") {
        guard let selectedID else { return }
        copy(selectedID)
      }
      if saveTags != nil {
        Button("Edit Tags…") { taggingID = selectedID }
      }
      if saveAsTemplate != nil {
        Button("Save as Template…") { templatingID = selectedID }
      }
      Divider()
      Button("Close Transaction", role: .destructive) {
        guard let selectedID else { return }
        tombstone(selectedID)
      }
    }
    .fixedSize()
    .disabled(selectedID == nil)
    .accessibilityLabel("Actions for the selected transaction")
  }

  @ViewBuilder private var quickAdd: some View {
    HStack(spacing: LedgerTheme.Space.xs) {
      TextField("Quick add amount", text: $macAmountLiteral)
        .textFieldStyle(.roundedBorder)
        .frame(width: 130)
        .accessibilityLabel("Quick add amount")
      Button("Add") {
        guard !macAmountLiteral.isEmpty else { return }
        addMacTransaction(macAmountLiteral)
      }
      .buttonStyle(LedgerSecondaryButtonStyle())
      .accessibilityLabel("Add Mac transaction")
    }
  }

  /// Opens the form for a Shortcuts request once the ledger's accounts have loaded, so the
  /// form never opens empty on a cold launch.
  private func presentIntentIfNeeded() {
    guard let intentRequest, !showingTransactionForm, !accounts.isEmpty else { return }
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
      HStack {
        Button(buttonTitle, action: open)
        if let importBackup {
          Button(LedgerAtlasRootView.importBackupActionTitle, action: importBackup)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(32)
  }
}
