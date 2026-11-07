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
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: LedgerTheme.Space.s) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(LedgerTheme.inkTertiary)
          .accessibilityHidden(true)
        TextField("Search accounts, memos, tags, status", text: $draft)
          .textFieldStyle(.plain)
          .font(LedgerTheme.Typeface.body)
          .onChange(of: draft) { _, value in onQuery(value) }
          .onAppear { draft = query }
          .accessibilityLabel("Search ledger")
          .accessibilityHint("Filters canonical transactions by memo, tag, kind, or status.")
      }
      .padding(.horizontal, LedgerTheme.Space.m)
      .frame(height: 32)
      .background(LedgerTheme.fieldFill, in: .rect(cornerRadius: LedgerTheme.Radius.row))
      .padding(LedgerTheme.Space.l)
      if rows.isEmpty {
        LedgerEmptyState(
          query.isEmpty ? "Search the ledger" : "No matching transactions", systemImage: "magnifyingglass",
          message: query.isEmpty ? emptyMessage : "Nothing matches “\(query)”. Try a memo, a tag, a kind or a status."
        ) {
          if query.isEmpty {
            Button("Open…", action: open).buttonStyle(LedgerSecondaryButtonStyle())
          }
        }
        .accessibilityLabel(query.isEmpty ? emptyMessage : "No matching transactions")
      } else {
        LedgerSurfaceRowList(rows: rows)
      }
    }
    .ledgerCanvas()
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
      LedgerEmptyState(destination.title, systemImage: "tray", message: emptyMessage) {
        Button("Open…", action: open).buttonStyle(LedgerPrimaryButtonStyle())
      }
      .ledgerCanvas()
      .navigationTitle(destination.title)
    } else {
      LedgerSurfaceRowList(rows: rows)
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
    LedgerCardColumn {
      VStack(alignment: .leading, spacing: LedgerTheme.Space.m) {
        LedgerCardHeader("This ledger")
        if rows.isEmpty {
          Text(emptyMessage)
            .font(LedgerTheme.Typeface.secondary)
            .foregroundStyle(LedgerTheme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
              LedgerKeyValue(row.title, row.detail)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(row.title), \(row.detail)")
              if row.id != rows.last?.id { LedgerRowDivider() }
            }
          }
          .padding(.horizontal, LedgerTheme.Space.m)
          .ledgerGroupBox()
        }
        if lastFailure != nil || status != nil {
          LedgerStatusLine(failure: lastFailure, status: status).textSelection(.enabled)
        }
      }
      .ledgerCard()

      VStack(alignment: .leading, spacing: LedgerTheme.Space.m) {
        LedgerCardHeader("Backups") { Text("Exact copies of this ledger") }
        Text("A 1:1 backup is the ledger file as it is, receipts included. Restoring one replaces the open ledger with that copy.")
          .font(LedgerTheme.Typeface.secondary)
          .foregroundStyle(LedgerTheme.inkSecondary)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: LedgerTheme.Space.s) {
          Button("Save 1:1 backup…", action: saveBackup)
            .buttonStyle(LedgerPrimaryButtonStyle())
            .accessibilityLabel("Save 1:1 backup")
          Button("Restore backup…", action: restoreBackup)
            .buttonStyle(LedgerSecondaryButtonStyle())
            .accessibilityLabel("Restore backup")
          Button("Open ledger…", action: open)
            .buttonStyle(LedgerSecondaryButtonStyle())
        }
      }
      .ledgerCard()

      VStack(alignment: .leading, spacing: LedgerTheme.Space.m) {
        LedgerCardHeader("Portable packages") { Text("For moving between Macs") }
        HStack(spacing: LedgerTheme.Space.s) {
          Button("Export portable package…", action: exportPackage)
            .buttonStyle(LedgerSecondaryButtonStyle())
            .accessibilityLabel("Export portable package")
          Button("Import portable package…", action: restorePackage)
            .buttonStyle(LedgerSecondaryButtonStyle())
            .accessibilityLabel("Import portable package")
        }
        Text(VendorExport.notice)
          .font(LedgerTheme.Typeface.caption)
          .foregroundStyle(LedgerTheme.inkTertiary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel(VendorExport.notice)
        if formatter.hidesAmounts {
          Text(LedgerProductSettings.hideAmountsExportNotice)
            .font(LedgerTheme.Typeface.caption).foregroundStyle(LedgerTheme.inkSecondary)
        }
      }
      .ledgerCard()

      if exportXLSX != nil || importXLSX != nil || reset != nil {
        VStack(alignment: .leading, spacing: LedgerTheme.Space.m) {
          LedgerCardHeader("Spreadsheets and reset")
          HStack(spacing: LedgerTheme.Space.s) {
            if let exportXLSX {
              Button("Export spreadsheet…", action: exportXLSX).buttonStyle(LedgerSecondaryButtonStyle())
            }
            if let importXLSX {
              Button("Import spreadsheet…", action: importXLSX).buttonStyle(LedgerSecondaryButtonStyle())
            }
            if let reset {
              Button("Reset ledger…", role: .destructive, action: reset)
                .buttonStyle(LedgerSecondaryButtonStyle())
                .accessibilityLabel("Reset ledger")
            }
          }
        }
        .ledgerCard()
      }
    }
    .navigationTitle("Backup")
  }
}
