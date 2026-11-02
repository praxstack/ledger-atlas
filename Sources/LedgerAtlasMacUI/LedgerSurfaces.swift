import AppKit
import CryptoKit
import LedgerCore
import LedgerStore
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

struct InsightsSurface: View {
  let rows: [LedgerJourney.SurfaceRow]
  let table: String
  let emptyMessage: String
  let open: () -> Void
  let exportPDF: () -> Void

  var body: some View {
    if rows.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        Text("Insights").font(.largeTitle.bold())
        Text(emptyMessage).foregroundStyle(.secondary)
        Button("Open…", action: open)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(32)
    } else {
      List {
        Section("Accessible table") {
          Text(table)
            .font(.body.monospaced())
            .textSelection(.enabled)
            .accessibilityLabel(table)
            .accessibilityAddTraits(.isStaticText)
        }
        Section("Status") {
          ForEach(rows) { row in
            HStack {
              Text(row.title)
              Spacer()
              Text(row.detail)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(row.title), \(row.detail)")
          }
        }
        Section("Export") {
          Button("Export PDF statement", action: exportPDF)
            .accessibilityLabel("Export PDF statement")
        }
      }
      .navigationTitle("Insights")
    }
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
  let rows: [LedgerJourney.SurfaceRow]
  let emptyMessage: String
  let lastFailure: String?
  let open: () -> Void
  let saveBackup: () -> Void
  let restoreBackup: () -> Void
  let exportPackage: () -> Void
  let restorePackage: () -> Void

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
      }
      HStack {
        Button("Open ledger…", action: open)
        Button("Save 1:1 backup…", action: saveBackup)
          .accessibilityLabel("Save 1:1 backup")
        Button("Restore backup…", action: restoreBackup)
          .accessibilityLabel("Restore backup as a new ledger")
        Button("Export portable package…", action: exportPackage)
          .accessibilityLabel("Export portable package")
        Button("Import portable package…", action: restorePackage)
          .accessibilityLabel("Import portable package as a new ledger")
      }
    }
    .padding(16)
    .navigationTitle("Backup")
  }
}
