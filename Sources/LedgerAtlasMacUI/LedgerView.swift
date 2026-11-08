import AppKit
import CryptoKit
import LedgerCore
import LedgerStore
import SwiftUI
import UniformTypeIdentifiers

struct LedgerView: View {
  @Environment(\.ledgerFormatter) private var formatter
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
  /// Answers what the entry form's Save did.
  let createTransaction:
    (String, String, LedgerTransactionKind, String, String?, String?, LedgerTagLinks)
      -> NativeEntrySaveResult
  let createSplit: (LedgerSplitDraft) -> Void
  var tags: [LedgerTag] = []
  var revisionTags: [String: LedgerTagLinks] = [:]
  /// (transaction ID, new tags).
  var saveTags: ((String, LedgerTagLinks) -> Void)?
  /// (transaction ID, template name).
  var saveAsTemplate: ((String, String) -> Void)?
  var editSplit: ((LedgerSplitDraft) -> Void)?
  var closeSplit: ((String) -> Void)?
  /// What is due soon (#171); the entry form shows it beside itself when the request asks.
  var upcoming: LedgerUpcoming? = nil
  /// Bulk edit (#168), from the journey: plan, write, revert and dismiss. Nil while read-only.
  var planBulkEdit: ((LedgerBulkChange, [String]) -> BulkEditPrompt)?
  var applyBulkEdit: ((LedgerBulkEditPlan) -> Void)?
  var lastBulkEdit: LedgerBulkEditReceipt? = nil
  var revertBulkEdit: (() -> Void)?
  var forgetBulkEdit: (() -> Void)?
  /// To Review (#238): only the waiting entries show, under a bar that marks them reviewed.
  var review: LedgerReviewMode? = nil

  /// The one selected entry; nil when none or several are selected.
  private var selectedID: String? { selectedIDs.count == 1 ? selectedIDs.first : nil }
  @State private var editingSplit: LedgerSplitPurchase?
  /// The selected entries; several give the bulk bar (#168).
  @State private var selectedIDs: Set<String> = []
  @State private var bulkPrompt: BulkEditPrompt?
  @State private var taggingID: String?
  @State private var templatingID: String?
  @State private var amountLiteral = ""
  @State private var macAmountLiteral = ""
  @State private var entryForm: EntryFormRequest?
  /// Upcoming as it was when the reminder opened the form; kept while the form stays open.
  @State private var showingSplitForm = false
  /// + New was pressed while read-only: the form opens once editing has begun.
  @State private var opensFormWhenEditing = false

  /// In To Review, every entry that isn't waiting is hidden too.
  private var hiddenIDs: Set<String> {
    guard let review else { return splitTransactionIDs }
    var hidden = splitTransactionIDs
    for transaction in transactions where !review.waitingIDs.contains(transaction.id) {
      hidden.insert(transaction.id)
    }
    return hidden
  }

  private var reviewIsEmpty: Bool {
    guard let review, case .loaded = state else { return false }
    return review.waitingIDs.isEmpty
  }

  var body: some View {
    Group {
      if reviewIsEmpty {
        ContentUnavailableView(
          LedgerReviewMode.emptyTitle, systemImage: "checkmark.circle",
          description: Text(LedgerReviewMode.emptyText))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .ledgerCanvas()
          .navigationTitle(LedgerReviewMode.title)
      } else if !transactions.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          if let splitNotice {
            Text(splitNotice)
              .font(LedgerTheme.Typeface.caption)
              .foregroundStyle(LedgerTheme.inkSecondary)
              .padding(.horizontal, LedgerTheme.Space.l)
              .padding(.top, LedgerTheme.Space.s)
              .accessibilityLabel(splitNotice)
          }
          LedgerBrowseList(
            transactions: transactions, hiddenIDs: hiddenIDs, accounts: accounts,
            categories: categories, splitPurchases: review == nil ? splitPurchases : [],
            selectedIDs: $selectedIDs,
            copy: copy, tombstone: tombstone, tags: tags, revisionTags: revisionTags,
            editTags: isEditing && saveTags != nil ? { (id: String) in taggingID = id } : nil,
            saveAsTemplate: isEditing && saveAsTemplate != nil
              ? { (id: String) in templatingID = id } : nil,
            editSplit: isEditing && editSplit != nil
              ? { (purchase: LedgerSplitPurchase) in editingSplit = purchase } : nil,
            closeSplit: isEditing && closeSplit != nil
              ? { (purchase: LedgerSplitPurchase) in closeSplit?(purchase.id) } : nil,
            bulkEdit: isEditing && planBulkEdit != nil
              ? { (change: LedgerBulkChange, ids: [String]) in
                bulkPrompt = planBulkEdit?(change, ids)
              } : nil)
        if let lifecycleMessage {
          Text(lifecycleMessage)
            .font(LedgerTheme.Typeface.caption)
            .foregroundStyle(LedgerTheme.inkSecondary)
            .accessibilityLabel(lifecycleMessage)
            .padding(.horizontal, LedgerTheme.Space.l)
            .padding(.vertical, LedgerTheme.Space.xs)
        }
        if let lastFailure {
          Label(lastFailure, systemImage: "exclamationmark.triangle")
            .font(LedgerTheme.Typeface.caption)
            .foregroundStyle(LedgerTheme.negative)
            .accessibilityLabel(lastFailure)
            .padding(.horizontal, LedgerTheme.Space.l)
            .padding(.vertical, LedgerTheme.Space.xs)
        }
        if let review {
          reviewBar(review)
        }
        if let lastBulkEdit, let revertBulkEdit {
          BulkEditNotice(
            text: BulkEditWording.done(lastBulkEdit, categories: categories, tags: tags),
            revert: revertBulkEdit, dismiss: { forgetBulkEdit?() })
        }
        editBar
          .padding(.horizontal, LedgerTheme.Space.l)
          .padding(.vertical, LedgerTheme.Space.s)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(LedgerTheme.recessed)
          .overlay(alignment: .top) { Divider().overlay(LedgerTheme.hairline) }
        }
        .navigationTitle(review == nil ? "Transactions" : LedgerReviewMode.title)
        .toolbar {
          if review == nil {
            ToolbarItem(placement: .primaryAction) {
              // The one primary action on the screen. Read-only, it begins editing first.
              Button {
                if isEditing {
                  entryForm = EntryFormRequest()
                } else {
                  opensFormWhenEditing = true
                  beginEditing()
                  // If editing can't begin (ledger busy or locked), forget the request, so a
                  // later Begin editing never pops the form up unasked.
                  Task {
                    try? await Task.sleep(for: .seconds(3))
                    opensFormWhenEditing = false
                  }
                }
              } label: {
                Label(Self.newTransactionTitle, systemImage: "plus")
                  .labelStyle(.titleAndIcon)
              }
              // The app's own primary style, so it is the teal accent like every other primary
              // action, not the system accent colour.
              .buttonStyle(LedgerPrimaryButtonStyle())
              .help("New transaction: add income or an expense")
            }
          }
        }
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
                Button("New transaction") { entryForm = EntryFormRequest() }
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
                Text(transaction.detail(hidingAmounts: formatter.hidesAmounts))
                  .font(LedgerTheme.Typeface.caption)
                  .foregroundStyle(LedgerTheme.inkSecondary)
              }
            }
          }
          .navigationTitle("Ledger")
        }
      }
    }
    .sheet(item: $entryForm) { request in
      EntryFormWithUpcoming(
        form: NativeTransactionForm(
          accounts: accounts, categories: categories, intent: intentRequest, tags: tags,
          entries: transactions,
          onSave: { submissionID, amount, kind, accountID, categoryID, note, links in
            let result = createTransaction(
              submissionID, amount, kind, accountID, categoryID, note, links)
            if case .notSaved = result {} else if intentRequest != nil { consumeIntent() }
            return result
          }),
        upcoming: request.upcoming, accounts: accounts, categories: categories)
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
    .sheet(item: $bulkPrompt) { prompt in
      switch prompt {
      case .confirm(let plan):
        BulkEditConfirmSheet(plan: plan, categories: categories, tags: tags) {
          applyBulkEdit?(plan)
        }
      case .refused(let message):
        BulkEditRefusedSheet(message: message)
      }
    }
    .focusedSceneValue(
      \.revertBulkEdit,
      lastBulkEdit != nil && revertBulkEdit != nil
        ? RevertBulkEditAction(perform: { revertBulkEdit?() }) : nil)
    .onChange(of: selectedID) { _, id in
      // Start an amount edit from the selected entry's current amount. With amounts hidden
      // (#173), selecting an entry must not show its amount, so the field starts empty.
      guard let id, !formatter.hidesAmounts,
        let amount = transactions.first(where: { $0.id == id })?.currentRevision.draft.effects
          .first?.amount.amount.rawLiteral
      else { return }
      amountLiteral = amount
    }
    .onChange(of: isEditing) { _, editing in
      guard editing, opensFormWhenEditing else { return }
      opensFormWhenEditing = false
      entryForm = EntryFormRequest()
    }
    .onDisappear { opensFormWhenEditing = false }
    .onAppear { presentIntentIfNeeded() }
    .onChange(of: intentRequest) { _, _ in presentIntentIfNeeded() }
    .onChange(of: accounts.count) { _, _ in presentIntentIfNeeded() }
  }

  /// How many entries wait, and Mark Reviewed for the selected ones or for all. Marking writes
  /// nothing to the ledger; editing an entry with the bar below also takes it off the list.
  private func reviewBar(_ review: LedgerReviewMode) -> some View {
    let picked = selectedIDs.filter { review.waitingIDs.contains($0) }
    return HStack(spacing: LedgerTheme.Space.m) {
      Text(LedgerReviewMode.waitingText(review.waitingIDs.count))
        .font(LedgerTheme.Typeface.captionEmphasis)
        .foregroundStyle(LedgerTheme.ink)
        .fixedSize()
      Text("Added for you by recurring dates, installments or imports.")
        .font(LedgerTheme.Typeface.caption)
        .foregroundStyle(LedgerTheme.inkTertiary)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: LedgerTheme.Space.s)
      Button(picked.count > 1 ? "Mark \(picked.count) Reviewed" : "Mark Reviewed") {
        review.markReviewed(Array(picked))
        selectedIDs.subtract(picked)
      }
      .buttonStyle(LedgerSecondaryButtonStyle())
      .disabled(picked.isEmpty)
      .fixedSize()
      .help("Take the selected entries off To Review. The ledger doesn't change.")
      Button("Mark All Reviewed") {
        review.markAllReviewed()
        selectedIDs = []
      }
      .buttonStyle(LedgerSecondaryButtonStyle())
      .fixedSize()
      .help("Take every entry off To Review. The ledger doesn't change.")
    }
    .padding(.horizontal, LedgerTheme.Space.l)
    .padding(.vertical, LedgerTheme.Space.s)
    .background(LedgerTheme.recessed)
    .overlay(alignment: .top) { Divider().overlay(LedgerTheme.hairline) }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("To Review actions")
  }

  /// Short, so the toolbar keeps the view switcher and the inspector toggle at 1,000 pt.
  static let newTransactionTitle = "New"

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
      entryForm = EntryFormRequest()
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
    guard let intentRequest, entryForm == nil, !accounts.isEmpty else { return }
    guard intentRequest.kind == .addExpense || intentRequest.kind == .addIncome else { return }
    entryForm = EntryFormRequest(upcoming: intentRequest.showsUpcoming ? upcoming : nil)
  }

  private func openPrompt(
    title: String, icon: String, description: String, buttonTitle: String,
    guidance: LedgerLifecycleGuidance? = nil, failure: String? = nil
  )
    -> some View
  {
    VStack(spacing: 12) {
      Image(systemName: icon).font(.largeTitle).foregroundStyle(LedgerTheme.inkTertiary)
      Text(title).font(.title2.bold())
      Text(description).foregroundStyle(LedgerTheme.inkSecondary)
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

/// One showing of the entry form. Upcoming travels with it, so the sheet never shows a value
/// from before it opened.
struct EntryFormRequest: Identifiable {
  let id = UUID()
  var upcoming: LedgerUpcoming? = nil
}

/// The entry form, with Upcoming beside it when the daily reminder opened it (#171).
struct EntryFormWithUpcoming: View {
  let form: NativeTransactionForm
  let upcoming: LedgerUpcoming?
  let accounts: [LedgerAccount]
  let categories: [LedgerCategory]

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      form
      if let upcoming {
        Divider()
        UpcomingPanel(upcoming: upcoming, accounts: accounts, categories: categories)
          .frame(width: 300)
          .frame(minHeight: 380, maxHeight: 560)
      }
    }
  }
}

/// To Review (#238) as `LedgerView` shows it: the entries waiting and what marking does.
struct LedgerReviewMode {
  let waitingIDs: Set<String>
  let markReviewed: ([String]) -> Void
  let markAllReviewed: () -> Void

  static let title = "To Review"
  static let emptyTitle = "Nothing to review"
  static let emptyText =
    "Entries the app adds for you (recurring dates, installments, imports) wait here until you've checked them."

  static func waitingText(_ count: Int) -> String {
    "\(count) \(count == 1 ? "entry" : "entries") to review"
  }
}
