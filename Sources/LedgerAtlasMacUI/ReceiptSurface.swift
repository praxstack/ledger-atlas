import AppKit
import LedgerCore
import LedgerStore
import SwiftUI
import UniformTypeIdentifiers

/// Receipts kept inside the open ledger. Text recognition runs on this Mac and only fills in
/// suggestions; a transaction is recorded only when the person confirms the expense form.
struct ReceiptSurface: View {
  let journey: LedgerJourney

  @State private var receipts: [LedgerReceiptAttachment] = []
  @State private var selectedID: String?
  @State private var draft: ReceiptOCRDraft?
  @State private var linkTarget: String?
  @State private var linkSearch = ""
  /// Built once per ledger change, so a large ledger isn't re-listed on every redraw.
  @State private var transactionRows: [LedgerJourney.SurfaceRow] = []
  @State private var rowsByID: [String: LedgerJourney.SurfaceRow] = [:]
  @State private var amount = ""
  @State private var accountID = ""
  @State private var categoryID: String?
  @State private var submissionID = UUID().uuidString
  @State private var status: String?
  @State private var isWorking = false

  private var selected: LedgerReceiptAttachment? {
    receipts.first { $0.id == selectedID }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Receipts").font(.largeTitle.bold())
      Text(
        "Receipts are stored inside the open ledger, so backups carry them. Images are kept as picked, including any location data they carry. Text recognition runs on this Mac and only suggests values; nothing is recorded until you confirm."
      )
      .foregroundStyle(.secondary)
      if journey.isEditing {
        Button("Add receipt…", action: chooseReceipt)
          .disabled(isWorking)
          .accessibilityLabel("Add receipt")
      } else {
        Text("Open a ledger for editing to add or link receipts.").foregroundStyle(.secondary)
      }
      if isWorking { ProgressView("Processing receipt…") }
      HStack(alignment: .top, spacing: 20) {
        receiptList.frame(minWidth: 220, maxWidth: 300)
        if let selected { detail(for: selected) }
      }
      if let status { Text(status).foregroundStyle(.secondary).accessibilityLabel(status) }
      Spacer()
    }
    .padding(24)
    .navigationTitle("Receipts")
    .task(id: journey.snapshotGeneration) { reload() }
  }

  private var receiptList: some View {
    List(selection: $selectedID) {
      if receipts.isEmpty {
        Text("No receipts yet.").foregroundStyle(.secondary)
      }
      ForEach(receipts, id: \.id) { receipt in
        VStack(alignment: .leading, spacing: 2) {
          Text(Self.title(for: receipt)).font(.headline)
          Text(linkText(for: receipt)).font(.caption).foregroundStyle(.secondary)
        }
        .tag(Optional(receipt.id))
        .accessibilityElement(children: .combine)
      }
    }
    .onChange(of: selectedID) { _, _ in resetForm() }
  }

  @ViewBuilder
  private func detail(for receipt: LedgerReceiptAttachment) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("\(receipt.byteCount) bytes · SHA-256 \(receipt.sha256.prefix(12))…")
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
      if receipt.lifecycle == .tombstoned {
        Text("Removed. It can't be linked or added again; its bytes stay in this ledger and its backups.")
          .foregroundStyle(.secondary)
      } else if journey.isEditing {
        linkChooser
        Button("Save link") { saveLink(receipt) }
          .disabled(isWorking || linkTarget == receipt.transactionID)

        Divider()
        if receipt.mediaType == .pdf {
          Text("Text recognition reads images only. Fill in the expense yourself.")
            .foregroundStyle(.secondary)
        } else {
          Button("Read text on this Mac") { recognize(receipt) }
            .disabled(isWorking)
        }
        if let draft, draft.attachmentID == receipt.id { suggestions(draft) }
        expenseForm(for: receipt)

        Divider()
        Button("Remove receipt", role: .destructive) { remove(receipt) }
          .accessibilityHint("Permanent: a removed receipt can't be linked or added again.")
          .disabled(isWorking)
      }
    }
  }

  /// Search instead of one long menu: the real ledger has thousands of transactions.
  private var linkChooser: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Linked transaction: \(label(for: linkTarget))")
      HStack {
        TextField("Search transactions", text: $linkSearch)
          .accessibilityLabel("Search transactions to link")
        Button("Not linked") { linkTarget = nil }
      }
      let matches = Self.matches(linkSearch, in: transactionRows)
      if !matches.isEmpty {
        ForEach(matches, id: \.id) { row in
          Button("\(row.title) · \(row.detail)") { linkTarget = row.id }
            .buttonStyle(.link)
        }
      }
    }
  }

  /// At most 20 rows whose title or detail contains the search text.
  static func matches(_ search: String, in rows: [LedgerJourney.SurfaceRow])
    -> [LedgerJourney.SurfaceRow]
  {
    let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return [] }
    var found: [LedgerJourney.SurfaceRow] = []
    for row in rows
    where row.title.localizedCaseInsensitiveContains(needle)
      || row.detail.localizedCaseInsensitiveContains(needle)
    {
      found.append(row)
      if found.count == 20 { break }
    }
    return found
  }

  private func label(for transactionID: String?) -> String {
    guard let transactionID else { return "none" }
    guard let row = rowsByID[transactionID] else { return "a transaction" }
    return "\(row.title) · \(row.detail)"
  }

  @ViewBuilder
  private func suggestions(_ draft: ReceiptOCRDraft) -> some View {
    if draft.lines.isEmpty {
      Text("No text was recognized.").foregroundStyle(.secondary)
    } else {
      let candidates = draft.amountCandidates
      if !candidates.isEmpty {
        HStack {
          Text("Amounts found (pick the total):")
          ForEach(candidates, id: \.self) { candidate in
            Button(candidate) { amount = candidate }
              .accessibilityHint("Uses this as the amount. Nothing is recorded until you confirm.")
          }
        }
      }
      DisclosureGroup("Recognized text (\(draft.lines.count) lines)") {
        ForEach(Array(draft.lines.enumerated()), id: \.offset) { index, line in
          Text("\(index + 1). \(line.text)")
            .accessibilityLabel("Line \(index + 1): \(line.text)")
        }
      }
    }
  }

  private func expenseForm(for receipt: LedgerReceiptAttachment) -> some View {
    let accounts = (journey.snapshot?.accounts ?? []).filter { $0.lifecycle == .active }
    let categories = (journey.snapshot?.categories ?? [])
      .filter { $0.lifecycle == .active && !$0.hidden && $0.kind.accepts(.expense) }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    return VStack(alignment: .leading, spacing: 8) {
      Text("Record as an expense").font(.headline)
      Picker("Account", selection: $accountID) {
        Text("Choose account…").tag("")
        ForEach(accounts, id: \.id) { Text($0.name).tag($0.id) }
      }
      Picker("Category", selection: $categoryID) {
        Text("No category").tag(String?.none)
        ForEach(categories, id: \.id) { Text($0.name).tag(Optional($0.id)) }
      }
      TextField("Amount", text: $amount)
      Button("Confirm and record expense") { recordExpense(from: receipt) }
        .disabled(isWorking || accountID.isEmpty || amount.isEmpty)
        .accessibilityHint("Records one expense from these values and links this receipt to it.")
    }
  }

  private func linkText(for receipt: LedgerReceiptAttachment) -> String {
    if receipt.lifecycle == .tombstoned { return "Removed" }
    guard let transactionID = receipt.transactionID else { return "Not linked" }
    guard let row = rowsByID[transactionID] else { return "Linked" }
    return "Linked to \(row.title) · \(row.detail)"
  }

  private static func title(for receipt: LedgerReceiptAttachment) -> String {
    let kind: String
    switch receipt.mediaType {
    case .jpeg: kind = "JPEG image"
    case .png: kind = "PNG image"
    case .heic: kind = "HEIC image"
    case .pdf: kind = "PDF"
    }
    let date = Date(timeIntervalSince1970: TimeInterval(receipt.createdAt.epochMilliseconds) / 1_000)
    return "\(kind), \(date.formatted(date: .abbreviated, time: .omitted))"
  }

  private func reload() {
    receipts = (try? journey.receiptAttachments()) ?? []
    transactionRows = journey.rows(for: .ledger)
    rowsByID = Dictionary(transactionRows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    if let selectedID, !receipts.contains(where: { $0.id == selectedID }) {
      self.selectedID = nil
    }
    linkTarget = selected?.transactionID
  }

  private func resetForm() {
    draft = nil
    amount = ""
    categoryID = nil
    submissionID = UUID().uuidString
    linkSearch = ""
    linkTarget = selected?.transactionID
  }

  private static var now: UTCInstant {
    UTCInstant(epochMilliseconds: UTCInstant.currentEpochMilliseconds())
  }

  private func chooseReceipt() {
    let panel = NSOpenPanel()
    panel.title = "Choose a receipt"
    panel.prompt = "Add"
    panel.allowedContentTypes = [.jpeg, .png, .heic, .pdf]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let source = panel.url else { return }
    let scoped = source.startAccessingSecurityScopedResource()
    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
    do {
      let receipt = try journey.addReceipt(from: source, createdAt: Self.now)
      reload()
      selectedID = receipt.id
      status = "Receipt added to the ledger."
    } catch ReceiptAttachmentError.sourceIsTooLarge {
      status = "The receipt is larger than the 25 MB limit."
    } catch ReceiptAttachmentError.sourceIsNotRegularFile {
      status = "Choose a receipt file, not a folder or alias."
    } catch LedgerStore.Error.unsupportedReceipt, ReceiptAttachmentError.unsupportedImage {
      status = "That file isn't a JPEG, PNG, HEIC or PDF receipt."
    } catch LedgerStore.Error.receiptRemoved {
      status = "This receipt was removed from the ledger earlier and can't be added again."
    } catch {
      status = "The receipt could not be added. Nothing was changed."
    }
  }

  private func recognize(_ receipt: LedgerReceiptAttachment) {
    let bytes: Data
    do { bytes = try journey.receiptBytes(receipt.id) } catch {
      status = "The receipt could not be read."
      return
    }
    isWorking = true
    status = nil
    let id = receipt.id
    Task {
      let result = await Task.detached(priority: .userInitiated) {
        Result { try ReceiptFiles.suggestions(for: bytes, attachmentID: id) }
      }.value
      switch result {
      case .success(let suggestions):
        // The largest number is often cash tendered, not the total, so nothing is pre-filled.
        draft = suggestions
        status = "Suggestions are ready. Pick the total or type it, then confirm to record an expense."
      case .failure(let error as ReceiptAttachmentError) where error == .unsupportedImage:
        status = "This image can't be read for text."
      case .failure:
        status = "Text recognition failed. Nothing was changed."
      }
      isWorking = false
    }
  }

  private func saveLink(_ receipt: LedgerReceiptAttachment) {
    do {
      try journey.linkReceipt(receipt.id, to: linkTarget)
      reload()
      status = linkTarget == nil ? "Receipt unlinked." : "Receipt linked."
    } catch {
      status = "The link could not be saved. Nothing was changed."
    }
  }

  private func recordExpense(from receipt: LedgerReceiptAttachment) {
    do {
      _ = try journey.createExpense(
        fromReceipt: receipt.id, amountLiteral: amount, accountID: accountID,
        categoryID: categoryID, createdAt: Self.now, submissionID: submissionID)
      reload()
      resetForm()
      status = "Expense recorded and the receipt linked to it."
    } catch ReceiptAttachmentError.expenseRecordedButNotLinked {
      status =
        "The expense was recorded, but the receipt couldn't be linked to it. Confirm again to retry the link; no second expense is recorded."
    } catch {
      status = LedgerJourney.editFailureMessage(
        for: error, otherwise: "The expense could not be recorded. Check the amount.")
    }
  }

  private func remove(_ receipt: LedgerReceiptAttachment) {
    do {
      try journey.removeReceipt(receipt.id)
      reload()
      status = "Receipt removed. It can't be linked or added again; its bytes stay in this ledger and its backups."
    } catch {
      status = "The receipt could not be removed."
    }
  }
}
