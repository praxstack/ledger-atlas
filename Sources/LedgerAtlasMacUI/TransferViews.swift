import AppKit
import CryptoKit
import LedgerCore
import LedgerStore
import SwiftUI
import UniformTypeIdentifiers

struct TransferSurface: View {
  let rows: [LedgerJourney.SurfaceRow]
  /// The ledger's transfers, newest first, shown as money rows (from → to, amount).
  var transfers: [LedgerTransactionSnapshot] = []
  let accounts: [LedgerAccount]
  let intentRequest: LedgerIntentRequest?
  let consumeIntent: () -> Void
  let isEditing: Bool
  let lastFailure: String?
  let beginEditing: () -> Void
  /// (submission ID, from, to, amount sent, amount received, fee, fee account).
  let createTransfer: (String, String, String, String, String?, String?, String?) -> Void
  @State private var showingForm = false
  @Environment(\.ledgerFormatter) private var formatter

  var body: some View {
    let activeCount = accounts.filter { $0.lifecycle == .active }.count
    VStack(alignment: .leading, spacing: 0) {
      if rows.isEmpty && transfers.isEmpty {
        LedgerEmptyState(
          "No transfers yet", systemImage: "arrow.left.arrow.right",
          message: "Transfers, currency conversions, and fees will appear here.")
      } else {
        transferList
      }
      LedgerActionBar {
        if isEditing {
          Button("New transfer") { showingForm = true }
            .buttonStyle(LedgerPrimaryButtonStyle())
            .accessibilityLabel("New transfer")
            .disabled(activeCount < 2)
        } else {
          Button("Begin editing", action: beginEditing)
            .buttonStyle(LedgerSecondaryButtonStyle())
            .accessibilityLabel("Begin editing")
        }
        if let lastFailure {
          LedgerStatusLine(failure: lastFailure)
        } else if activeCount < 2 {
          LedgerStatusLine(status: "Create at least two active accounts before recording a transfer.")
        }
      }
    }
    .ledgerCanvas()
    .navigationTitle("Transfers")
    .sheet(isPresented: $showingForm) {
      NativeTransferForm(
        accounts: accounts, intent: intentRequest,
        onSave: { submissionID, sourceID, destinationID, sourceAmount, destinationAmount, feeAmount,
          feeAccountID in
          createTransfer(
            submissionID, sourceID, destinationID, sourceAmount, destinationAmount, feeAmount,
            feeAccountID)
          if intentRequest?.kind == .addTransfer { consumeIntent() }
        })
    }
    .onAppear { presentIntentIfNeeded() }
    .onChange(of: intentRequest) { _, _ in presentIntentIfNeeded() }
    .onChange(of: accounts.count) { _, _ in presentIntentIfNeeded() }
  }

  private func presentIntentIfNeeded() {
    guard intentRequest?.kind == .addTransfer, !showingForm, accounts.count >= 2 else { return }
    showingForm = true
  }

  /// Transfers as money rows grouped by month, newest first; source records kept from a
  /// backup follow as plain rows.
  private var transferList: some View {
    let names = Dictionary(accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    // The same colours the sidebar and Accounts give each account.
    let swatches = LedgerTheme.accountSwatches(
      for: accounts.filter { $0.lifecycle == .active && !$0.hidden }.map(\.name))
    let transferIDs = Set(transfers.map(\.id))
    return List {
      ForEach(Self.months(transfers), id: \.month) { group in
        Section {
          ForEach(group.transfers, id: \.id) { transfer in
            TransferMoneyRow(transfer: transfer, accountNames: names, swatches: swatches)
          }
        } header: {
          HStack(alignment: .firstTextBaseline) {
            Text(formatter.monthTitle(group.month))
              .font(LedgerTheme.Typeface.captionEmphasis)
              .foregroundStyle(LedgerTheme.inkSecondary)
            Spacer(minLength: LedgerTheme.Space.s)
            Text(group.transfers.count == 1 ? "1 transfer" : "\(group.transfers.count) transfers")
              .font(LedgerTheme.Typeface.caption)
              .foregroundStyle(LedgerTheme.inkTertiary)
          }
          .accessibilityElement(children: .combine)
          .accessibilityAddTraits(.isHeader)
        }
      }
      // Rows for transfer transactions carry the transfer kind as detail; only the source
      // records kept from a backup remain.
      ForEach(
        rows.filter {
          !transferIDs.contains($0.id) && $0.detail != LedgerTransactionKind.transfer.rawValue
        }
      ) { row in
        LedgerRow(row.title, detail: row.detail)
          .accessibilityElement(children: .combine)
          .accessibilityLabel("\(row.title), \(row.detail)")
      }
    }
    .scrollContentBackground(.hidden)
    .ledgerCanvas()
  }

  /// Transfers by the month they happened in, newest month first; the order inside a month is
  /// kept.
  static func months(_ transfers: [LedgerTransactionSnapshot])
    -> [(month: SourceLocalDate, transfers: [LedgerTransactionSnapshot])]
  {
    var order: [SourceLocalDate] = []
    var groups: [SourceLocalDate: [LedgerTransactionSnapshot]] = [:]
    for transfer in transfers {
      let day = transfer.currentRevision.draft.occurredAt.localDay
      guard let month = try? SourceLocalDate(year: day.year, month: day.month, day: 1) else { continue }
      if groups[month] == nil { order.append(month) }
      groups[month, default: []].append(transfer)
    }
    return order.sorted(by: >).map { ($0, groups[$0] ?? []) }
  }
}

struct NativeTransferForm: View {
  let accounts: [LedgerAccount]
  let intent: LedgerIntentRequest?
  let onSave: (String, String, String, String, String?, String?, String?) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var submissionID = UUID().uuidString
  @State private var isSaving = false
  @State private var sourceAccountID = ""
  @State private var destinationAccountID = ""
  @State private var sourceAmount = ""
  @State private var destinationAmount = ""
  @State private var feeAmount = ""
  @State private var feeAccountID: String?

  init(
    accounts: [LedgerAccount], intent: LedgerIntentRequest? = nil,
    onSave: @escaping (String, String, String, String, String?, String?, String?) -> Void
  ) {
    self.accounts = accounts
    self.intent = intent
    self.onSave = onSave
    _sourceAmount = State(initialValue: intent?.kind == .addTransfer ? intent?.amountLiteral ?? "" : "")
  }

  private var activeAccounts: [LedgerAccount] {
    accounts.filter { $0.lifecycle == .active }.sorted { $0.name < $1.name }
  }

  private var sourceUnit: String? {
    activeAccounts.first(where: { $0.id == sourceAccountID })?.currencyUnit
  }

  private var destinationUnit: String? {
    activeAccounts.first(where: { $0.id == destinationAccountID })?.currencyUnit
  }

  private var needsConversion: Bool {
    sourceUnit != nil && destinationUnit != nil && sourceUnit != destinationUnit
  }

  var body: some View {
    Form {
      if activeAccounts.count < 2 {
        ContentUnavailableView(
          "Two active accounts required", systemImage: "arrow.left.arrow.right",
          description: Text("Create two active accounts before recording a transfer."))
      } else {
        Picker("From account", selection: $sourceAccountID) {
          ForEach(activeAccounts, id: \.id) { account in
            Text("\(account.name) (\(account.currencyUnit))").tag(account.id)
          }
        }
        Picker("To account", selection: $destinationAccountID) {
          ForEach(activeAccounts, id: \.id) { account in
            Text("\(account.name) (\(account.currencyUnit))").tag(account.id)
          }
        }
        TextField("Amount sent", text: $sourceAmount)
          .accessibilityLabel("Transfer amount sent")
        if needsConversion {
          TextField("Amount received", text: $destinationAmount)
            .accessibilityLabel("Transfer amount received")
          if let sourceUnit, let destinationUnit,
            let preview = LedgerJourney.conversionPreview(
              sourceLiteral: sourceAmount, sourceUnit: sourceUnit,
              destinationLiteral: destinationAmount, destinationUnit: destinationUnit)
          {
            Text("Rate: \(preview)")
              .font(LedgerTheme.Typeface.caption)
              .foregroundStyle(LedgerTheme.inkSecondary)
              .accessibilityLabel("Exchange rate \(preview)")
          } else {
            Text("The exchange rate is worked out from the two amounts.")
              .font(LedgerTheme.Typeface.caption)
              .foregroundStyle(LedgerTheme.inkSecondary)
          }
        } else {
          Text("Destination amount equals the amount sent.")
            .font(LedgerTheme.Typeface.caption)
            .foregroundStyle(LedgerTheme.inkSecondary)
        }
        TextField("Fee (optional)", text: $feeAmount)
          .accessibilityLabel("Transfer fee")
        Picker("Fee account", selection: $feeAccountID) {
          Text("No fee account").tag(String?.none)
          ForEach(activeAccounts, id: \.id) { account in
            Text("\(account.name) (\(account.currencyUnit))").tag(Optional(account.id))
          }
        }
        HStack {
          Button("Cancel", role: .cancel) { dismiss() }
          Spacer()
          Button("Save") { save() }
            .disabled(
              isSaving || sourceAccountID.isEmpty || destinationAccountID.isEmpty
                || sourceAccountID == destinationAccountID || sourceAmount.isEmpty
                || (needsConversion && destinationAmount.isEmpty)
                || (!feeAmount.isEmpty && feeAccountID == nil))
        }
      }
    }
    .padding(20)
    .frame(width: 480)
    .onAppear {
      if sourceAccountID.isEmpty { sourceAccountID = activeAccounts.first?.id ?? "" }
      if destinationAccountID.isEmpty {
        destinationAccountID = activeAccounts.dropFirst().first?.id ?? ""
      }
    }
    .onChange(of: sourceAccountID) { _, _ in clearConversionIfSameUnit() }
    .onChange(of: destinationAccountID) { _, _ in clearConversionIfSameUnit() }
    .accessibilityElement(children: .contain)
  }

  private func clearConversionIfSameUnit() {
    guard !needsConversion else { return }
    destinationAmount = ""
  }

  private func save() {
    guard !isSaving else { return }
    isSaving = true
    onSave(
      submissionID, sourceAccountID, destinationAccountID, sourceAmount,
      needsConversion ? destinationAmount : nil,
      feeAmount.isEmpty ? nil : feeAmount, feeAmount.isEmpty ? nil : feeAccountID)
    dismiss()
  }
}

/// One transfer: an arrow tile, "From → To" with the date, and the amount sent.
struct TransferMoneyRow: View {
  let transfer: LedgerTransactionSnapshot
  let accountNames: [String: String]
  /// Account colours by name, as in the sidebar.
  var swatches: [String: LedgerTheme.Swatch] = [:]
  @Environment(\.ledgerFormatter) private var formatter

  private var draft: LedgerTransactionDraft { transfer.currentRevision.draft }
  private var sent: LedgerTransactionEffect? { draft.effects.first { $0.direction == .decrease } }
  private var received: LedgerTransactionEffect? {
    draft.effects.first { $0.direction == .increase && $0.accountID != sent?.accountID }
  }

  private var fromName: String { sent.flatMap { accountNames[$0.accountID] } ?? "Unknown account" }
  private var toName: String { received.flatMap { accountNames[$0.accountID] } ?? "Unknown account" }
  private var route: String { "\(fromName) → \(toName)" }

  private var detail: String {
    var parts = [formatter.date(draft.occurredAt.localDay)]
    if let sent, let received, sent.amount.unitCode != received.amount.unitCode {
      parts.append("received \(formatter.amount(received.amount))")
    }
    if let note = draft.note?.split(whereSeparator: \.isNewline).first, !note.isEmpty {
      parts.append(String(note))
    }
    return parts.joined(separator: " · ")
  }

  var body: some View {
    HStack(spacing: LedgerTheme.Space.m) {
      LedgerIconTile(
        .symbol("arrow.left.arrow.right"),
        swatch: LedgerTheme.Swatch(color: LedgerTheme.accent, soft: LedgerTheme.accentSoft))
      VStack(alignment: .leading, spacing: LedgerTheme.Space.xxs) {
        HStack(spacing: LedgerTheme.Space.xs) {
          account(fromName)
          Image(systemName: "arrow.right")
            .font(LedgerTheme.Typeface.caption)
            .foregroundStyle(LedgerTheme.inkTertiary)
          account(toName)
        }
        .lineLimit(1)
        Text(detail)
          .font(LedgerTheme.Typeface.caption)
          .foregroundStyle(LedgerTheme.inkTertiary)
          .lineLimit(1)
      }
      Spacer(minLength: LedgerTheme.Space.s)
      if let sent {
        MoneyText(sent.amount, size: .row, sign: .never, tone: .neutral)
      }
    }
    .padding(.vertical, LedgerTheme.Space.xxs)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "Transfer, \(route), \(sent.map { formatter.amount($0.amount) } ?? ""), \(detail)")
  }

  /// An account name with its colour key, so the two ends of a transfer read at a glance.
  private func account(_ name: String) -> some View {
    HStack(spacing: LedgerTheme.Space.xs) {
      if let swatch = swatches[name] { LedgerColorKey(swatch.color) }
      Text(name)
        .font(LedgerTheme.Typeface.bodyEmphasis)
        .foregroundStyle(LedgerTheme.ink)
    }
  }
}
