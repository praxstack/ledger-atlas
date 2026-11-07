import AppKit
import CryptoKit
import LedgerCore
import LedgerStore
internal import MMImport
import SwiftUI
import UniformTypeIdentifiers

struct SearchSurface: View {
  let rows: [LedgerJourney.SurfaceRow]
  let query: String
  let emptyMessage: String
  let onQuery: (String) -> Void
  let open: () -> Void
  @State private var draft = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      TextField("Search accounts, memos, tags, status", text: $draft)
        .textFieldStyle(.roundedBorder)
        .onChange(of: draft) { _, value in onQuery(value) }
        .onAppear { draft = query }
        .accessibilityLabel("Search ledger")
        .accessibilityHint("Filters canonical transactions by memo, tag, kind, or status.")
      if rows.isEmpty {
        Text(query.isEmpty ? emptyMessage : "No matching transactions.")
          .foregroundStyle(.secondary)
          .accessibilityLabel(query.isEmpty ? emptyMessage : "No matching transactions")
        Button("Open…", action: open)
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
    }
    .padding(query.isEmpty && rows.isEmpty ? 32 : 16)
    .navigationTitle("Search")
  }
}

struct DataBackedSurface: View {
  let destination: AppDestination
  let rows: [LedgerJourney.SurfaceRow]
  let emptyMessage: String
  let open: () -> Void

  var body: some View {
    if rows.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        Text(destination.title).font(.largeTitle.bold())
        Text(emptyMessage).foregroundStyle(.secondary)
        Button("Open…", action: open)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(32)
    } else {
      List(rows) { row in
        VStack(alignment: .leading, spacing: 4) {
          Text(row.title)
          Text(row.detail).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.title), \(row.detail)")
      }
      .navigationTitle(destination.title)
    }
  }
}

struct BackupSurface: View {
  @Environment(\.ledgerFormatter) private var formatter
  let rows: [LedgerJourney.SurfaceRow]
  let emptyMessage: String
  let lastFailure: String?
  var status: String? = nil
  let open: () -> Void
  let saveBackup: () -> Void
  let restoreBackup: () -> Void
  let exportPackage: () -> Void
  let restorePackage: () -> Void
  /// Contents-only or complete reset. Nil hides the button.
  var reset: (() -> Void)? = nil
  /// Spreadsheet exchange, wired by the XLSX work. Nil hides the buttons.
  var exportXLSX: (() -> Void)? = nil
  var importXLSX: (() -> Void)? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if rows.isEmpty {
        Text("Backup").font(.largeTitle.bold())
        Text(emptyMessage).foregroundStyle(.secondary)
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
      } else if let status {
        Text(status).foregroundStyle(.secondary).textSelection(.enabled)
          .accessibilityLabel(status)
      }
      HStack {
        Button("Open ledger…", action: open)
        Button("Save 1:1 backup…", action: saveBackup)
          .accessibilityLabel("Save 1:1 backup")
        Button("Restore backup…", action: restoreBackup)
          .accessibilityLabel("Restore backup")
        Button("Export portable package…", action: exportPackage)
          .accessibilityLabel("Export portable package")
        Button("Import portable package…", action: restorePackage)
          .accessibilityLabel("Import portable package")
      }
      Text(VendorExport.notice).font(.caption).foregroundStyle(.secondary)
        .accessibilityLabel(VendorExport.notice)
      if formatter.hidesAmounts {
        Text(LedgerProductSettings.hideAmountsExportNotice)
          .font(.caption).foregroundStyle(.secondary)
      }
      if exportXLSX != nil || importXLSX != nil || reset != nil {
        HStack {
          if let exportXLSX {
            Button("Export spreadsheet…", action: exportXLSX)
          }
          if let importXLSX {
            Button("Import spreadsheet…", action: importXLSX)
          }
          if let reset {
            Button("Reset ledger…", role: .destructive, action: reset)
              .accessibilityLabel("Reset ledger")
          }
        }
      }
    }
    .padding(16)
    .navigationTitle("Backup")
  }
}
