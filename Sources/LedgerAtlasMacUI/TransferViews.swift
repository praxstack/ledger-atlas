import AppKit
import CryptoKit
import LedgerCore
import LedgerStore
import SwiftUI
import UniformTypeIdentifiers

struct TransferSurface: View {
  let rows: [LedgerJourney.SurfaceRow]
  let accounts: [LedgerAccount]
  let intentRequest: LedgerIntentRequest?
  let consumeIntent: () -> Void
  let isEditing: Bool
  let lastFailure: String?
  let beginEditing: () -> Void
  /// (submission ID, from, to, amount sent, amount received, fee, fee account).
  let createTransfer: (String, String, String, String, String?, String?, String?) -> Void
  @State private var showingForm = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if rows.isEmpty {
        Text("No transfers yet").font(.title2.bold())
        Text("Transfers, currency conversions, and fees will appear here.")
          .foregroundStyle(.secondary)
      } else {
        List(rows) { row in
          VStack(alignment: .leading, spacing: 4) {
            Text(row.title)
            Text(row.detail).font(.caption).foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel("\(row.title), \(row.detail)")
        }
      }
      if let lastFailure {
        Text(lastFailure).foregroundStyle(.red).accessibilityLabel(lastFailure)
      }
      if isEditing {
        Button("New transfer") { showingForm = true }
          .accessibilityLabel("New transfer")
          .disabled(accounts.filter { $0.lifecycle == .active }.count < 2)
      } else {
        Button("Begin editing", action: beginEditing)
          .accessibilityLabel("Begin editing")
      }
      if accounts.filter({ $0.lifecycle == .active }).count < 2 {
        Text("Create at least two active accounts before recording a transfer.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(16)
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
  }

  private func presentIntentIfNeeded() {
    guard intentRequest?.kind == .addTransfer, !showingForm else { return }
    showingForm = true
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
              .font(.caption)
              .foregroundStyle(.secondary)
              .accessibilityLabel("Exchange rate \(preview)")
          } else {
            Text("The exchange rate is worked out from the two amounts.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } else {
          Text("Destination amount equals the amount sent.")
            .font(.caption)
            .foregroundStyle(.secondary)
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
