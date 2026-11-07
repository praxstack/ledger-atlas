import AppKit
import CryptoKit
import LedgerCore
import LedgerStore
internal import MMImport
import SwiftUI
import UniformTypeIdentifiers

struct SearchSurface: View {
  /// Matching transactions, newest first, built by `LedgerBrowser` so a result reads exactly
  /// like the same entry on Transactions.
  let results: [LedgerBrowseEntry]
  let accountNames: [String: String]
  let categoryNames: [String: String]
  let tagNames: [String: String]
  let query: String
  let emptyMessage: String
  let onQuery: (String) -> Void
  let open: () -> Void
  @State private var draft = ""
  @FocusState private var fieldIsFocused: Bool
  @Environment(\.ledgerFormatter) private var formatter

  private struct Day: Identifiable {
    let date: SourceLocalDate
    var entries: [LedgerBrowseEntry]
    var id: SourceLocalDate { date }
  }

  /// Results grouped by day, newest day first; `results` is already sorted.
  private var days: [Day] {
    var grouped: [Day] = []
    for entry in results {
      if let last = grouped.last, last.date == entry.occurredAt.date {
        grouped[grouped.count - 1].entries.append(entry)
      } else {
        grouped.append(Day(date: entry.occurredAt.date, entries: [entry]))
      }
    }
    return grouped
  }

  private var subtitle: String {
    if query.isEmpty { return "" }
    return results.count == 1 ? "1 result" : "\(results.count) results"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      field
        .padding(.horizontal, LedgerTheme.Space.l)
        .padding(.top, LedgerTheme.Space.m)
        .padding(.bottom, LedgerTheme.Space.m)
      Divider().overlay(LedgerTheme.hairline)
      if results.isEmpty {
        LedgerEmptyState(
          query.isEmpty ? "Search the ledger" : "No matching transactions", systemImage: "magnifyingglass",
          message: query.isEmpty
            ? emptyMessage : "Nothing matches “\(query)”. Try a memo, a tag, a kind or a status."
        ) {
          if query.isEmpty {
            Button("Open…", action: open).buttonStyle(LedgerSecondaryButtonStyle())
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(query.isEmpty ? emptyMessage : "No matching transactions")
      } else {
        List {
          ForEach(days) { day in
            Section {
              ForEach(day.entries) { entry in
                SearchResultRow(
                  entry: entry, accountNames: accountNames, categoryNames: categoryNames,
                  tagNames: tagNames)
              }
            } header: {
              Text(formatter.date(day.date, style: .full))
                .font(LedgerTheme.Typeface.caption.weight(.semibold))
                .foregroundStyle(LedgerTheme.inkSecondary)
                .accessibilityAddTraits(.isHeader)
            }
          }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
      }
    }
    .ledgerCanvas()
    .navigationTitle("Search")
    .navigationSubtitle(subtitle)
    .onAppear {
      draft = query
      fieldIsFocused = true
    }
  }

  private var field: some View {
    HStack(spacing: LedgerTheme.Space.s) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(LedgerTheme.inkTertiary)
        .accessibilityHidden(true)
      TextField("Search memos, tags, accounts and status", text: $draft)
        .textFieldStyle(.plain)
        .font(LedgerTheme.Typeface.body)
        .focused($fieldIsFocused)
        .onChange(of: draft) { _, value in onQuery(value) }
        .accessibilityLabel("Search ledger")
        .accessibilityHint("Filters transactions by memo, tag, kind, or status.")
      if !draft.isEmpty {
        Button {
          draft = ""
          fieldIsFocused = true
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(LedgerTheme.inkTertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
        .help("Clear search")
      }
    }
    .padding(.horizontal, LedgerTheme.Space.m)
    .frame(height: 32)
    .background(LedgerTheme.fieldFill, in: .rect(cornerRadius: LedgerTheme.Radius.row))
    .overlay {
      RoundedRectangle(cornerRadius: LedgerTheme.Radius.row)
        .strokeBorder(fieldIsFocused ? LedgerTheme.accent : LedgerTheme.hairline, lineWidth: 1)
    }
  }
}

/// One search result, laid out like a Transactions row: category tile, what it was for, where
/// the money moved, and the signed amount through `MoneyText`.
struct SearchResultRow: View {
  let entry: LedgerBrowseEntry
  let accountNames: [String: String]
  let categoryNames: [String: String]
  let tagNames: [String: String]
  @Environment(\.ledgerFormatter) private var formatter

  var body: some View {
    let category = entry.categoryID.flatMap { categoryNames[$0] }
    let account = entry.accountIDs.compactMap { accountNames[$0] }.joined(separator: " → ")
    let title = category ?? entry.kind.rawValue.capitalized
    let signed = LedgerBrowseList.signedAmount(entry)
    let tags = entry.tagIDs.compactMap { tagNames[$0] }.sorted {
      $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }.map { "#\($0)" }
    let detail = ([account.isEmpty ? nil : account, entry.note] + tags).compactMap { $0 }
      .joined(separator: " · ")
    let kind = category == nil ? nil : entry.kind.rawValue.capitalized
    let spoken = [
      title, kind, detail.isEmpty ? nil : detail,
      formatter.hidesAmounts
        ? LedgerDisplayFormatter.hiddenAmountLabel : formatter.parts(signed.amount, sign: signed.sign).text,
      entry.lifecycle == .tombstoned ? "closed" : nil,
    ].compactMap { $0 }.joined(separator: ", ")

    HStack(alignment: .center, spacing: LedgerTheme.Space.m) {
      LedgerIconTile(
        .symbol(LedgerCategorySymbol.name(for: category, kind: entry.kind)),
        swatch: LedgerTheme.swatch(for: title))
      VStack(alignment: .leading, spacing: LedgerTheme.Space.xxs) {
        Text(title)
          .font(LedgerTheme.Typeface.body)
          .foregroundStyle(LedgerTheme.ink)
          .strikethrough(entry.lifecycle == .tombstoned)
          .lineLimit(1)
        if !detail.isEmpty {
          Text(detail)
            .font(LedgerTheme.Typeface.caption)
            .foregroundStyle(LedgerTheme.inkSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }
      .layoutPriority(1)
      Spacer(minLength: LedgerTheme.Space.s)
      MoneyText(signed.amount, size: .row, sign: signed.sign)
        .fixedSize()
    }
    .frame(minHeight: LedgerTheme.Metrics.tableRow - 4)
    .padding(.vertical, LedgerTheme.Space.xxs)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(spoken)
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

  static func exportStatusSymbol(for rowID: String) -> (symbol: String, tint: Color)? {
    switch rowID {
    case "manifest": ("checkmark.seal.fill", LedgerTheme.positive)
    case "manifest-limit": ("info.circle.fill", LedgerTheme.inkSecondary)
    case "manifest-failed": ("exclamationmark.triangle.fill", LedgerTheme.negative)
    default: nil
    }
  }
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
  /// Saves the open ledger's receipt key for another Mac (#182). Nil hides the button.
  var saveRecoveryKey: (() -> Void)? = nil
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
              HStack(spacing: LedgerTheme.Space.s) {
                if let status = Self.exportStatusSymbol(for: row.id) {
                  // Healthy, limited or failed at a glance, and never by colour alone: the words say it too.
                  Image(systemName: status.symbol)
                    .foregroundStyle(status.tint)
                    .accessibilityHidden(true)
                }
                LedgerKeyValue(row.title, row.detail)
              }
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
        if let saveRecoveryKey {
          Button("Save recovery key…", action: saveRecoveryKey)
            .buttonStyle(LedgerSecondaryButtonStyle())
            .accessibilityLabel("Save recovery key")
            .help("A ledger with imported history needs this key to open on another Mac.")
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

      if exportXLSX != nil || importXLSX != nil {
        VStack(alignment: .leading, spacing: LedgerTheme.Space.m) {
          LedgerCardHeader("Spreadsheets") { Text("Excel workbooks") }
          HStack(spacing: LedgerTheme.Space.s) {
            if let exportXLSX {
              Button("Export spreadsheet…", action: exportXLSX).buttonStyle(LedgerSecondaryButtonStyle())
            }
            if let importXLSX {
              Button("Import spreadsheet…", action: importXLSX).buttonStyle(LedgerSecondaryButtonStyle())
            }
          }
        }
        .ledgerCard()
      }

      if let reset {
        VStack(alignment: .leading, spacing: LedgerTheme.Space.m) {
          LedgerCardHeader("Reset")
          Text("Resetting removes this ledger's contents. Save a 1:1 backup first if you may want them back.")
            .font(LedgerTheme.Typeface.secondary)
            .foregroundStyle(LedgerTheme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
          Button("Reset ledger…", role: .destructive, action: reset)
            .buttonStyle(LedgerDestructiveButtonStyle())
            .accessibilityLabel("Reset ledger")
        }
        .ledgerCard()
      }
    }
    .navigationTitle(AppDestination.backupRestore.sidebarTitle)
  }
}
