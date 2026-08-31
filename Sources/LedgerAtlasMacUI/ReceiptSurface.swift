import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ReceiptSurface: View {
  @State private var attachment: ReceiptAttachment?
  @State private var draft: ReceiptOCRDraft?
  @State private var status: String?
  @State private var isWorking = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Receipts").font(.largeTitle.bold())
      Text("Receipt bytes stay in private application storage. Local OCR creates suggestions only; it never writes a transaction.")
        .foregroundStyle(.secondary)
      HStack {
        Button("Choose receipt…", action: chooseReceipt)
          .disabled(isWorking)
          .accessibilityLabel("Choose receipt")
        if attachment != nil {
          Button("Remove receipt", role: .destructive, action: removeReceipt)
            .disabled(isWorking)
        }
      }
      if isWorking { ProgressView("Processing receipt…") }
      if let attachment {
        VStack(alignment: .leading, spacing: 4) {
          Text(attachment.filename).font(.headline)
          Text("\(attachment.byteCount) bytes · SHA-256 \(attachment.sha256.prefix(12))…")
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Receipt \(attachment.filename), \(attachment.byteCount) bytes")
      }
      if let draft {
        Section("Local OCR suggestions") {
          if draft.lines.isEmpty {
            Text("No text was recognized.").foregroundStyle(.secondary)
          } else {
            ForEach(Array(draft.lines.enumerated()), id: \.offset) { index, line in
              HStack(alignment: .firstTextBaseline) {
                Text("\(index + 1). \(line.text)")
                Spacer()
                Text(String(format: "%.0f%%", line.confidence * 100))
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
              }
              .accessibilityElement(children: .combine)
              .accessibilityLabel("Suggestion \(index + 1): \(line.text)")
            }
          }
          if draft.confirmed {
            Label("Reviewed. No financial entry was created.", systemImage: "checkmark.circle")
              .foregroundStyle(.green)
          } else {
            Button("Confirm suggestions for review") { confirmSuggestions() }
              .disabled(draft.lines.isEmpty)
              .accessibilityHint("Marks OCR suggestions reviewed without changing ledger data.")
          }
        }
      }
      if let status { Text(status).foregroundStyle(.secondary).accessibilityLabel(status) }
      Spacer()
    }
    .padding(24)
    .navigationTitle("Receipts")
  }

  private func chooseReceipt() {
    let panel = NSOpenPanel()
    panel.title = "Choose a receipt image"
    panel.prompt = "Import"
    panel.allowedContentTypes = [.image]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let source = panel.url else { return }
    guard source.startAccessingSecurityScopedResource() else {
      status = "Receipt access was not granted."
      return
    }
    isWorking = true
    status = nil
    Task {
      defer { source.stopAccessingSecurityScopedResource() }
      do {
        let store = try ReceiptAttachmentStore(rootURL: Self.storageURL)
        let imported = try await store.importFile(from: source)
        let suggestions = try await store.suggestions(for: imported)
        attachment = imported
        draft = suggestions
        status = "Receipt imported and analyzed locally."
      } catch ReceiptAttachmentError.unsupportedImage {
        status = "The receipt file is not a supported image."
      } catch ReceiptAttachmentError.sourceIsTooLarge {
        status = "The receipt is larger than the 25 MB limit."
      } catch {
        status = "Receipt processing failed without changing ledger data."
      }
      isWorking = false
    }
  }

  private func confirmSuggestions() {
    guard let draft else { return }
    self.draft = try? draft.confirm()
    status = "Suggestions marked reviewed. No financial entry was created."
  }

  private func removeReceipt() {
    guard let attachment else { return }
    isWorking = true
    Task {
      do {
        let store = try ReceiptAttachmentStore(rootURL: Self.storageURL)
        try await store.remove(attachment)
        self.attachment = nil
        draft = nil
        status = "Receipt removed from private storage."
      } catch {
        status = "Receipt could not be removed."
      }
      isWorking = false
    }
  }

  private static var storageURL: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("Ledger Atlas/Receipts", isDirectory: true)
  }
}
