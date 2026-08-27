import AppKit
import LedgerCore
import SwiftUI
import UniformTypeIdentifiers

public struct LedgerAtlasRootView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var selection: AppDestination
  @State private var session = LedgerSession()
  @State private var journey = LedgerJourney()
  @State private var isChoosingLedger = false
  @State private var sourceTimeZoneIdentifier = ""
  private let bookmarkStore = SecurityScopedBookmarkStore()
  private let widgetProjectionPublisher: RedactedWidgetProjectionPublisher?
  private let importReviewSummary: ImportReviewSummary

  public init(
    initialSelection: AppDestination = .defaultSelection,
    importReviewSummary: ImportReviewSummary? = nil
  ) {
    _selection = State(initialValue: initialSelection)
    self.importReviewSummary = importReviewSummary ?? .awaitingSyntheticMetadata
    widgetProjectionPublisher = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: RedactedWidgetProjectionStore.appGroupIdentifier)
      .map { RedactedWidgetProjectionPublisher(store: .init(containerURL: $0)) }
  }

  public var body: some View {
    NavigationSplitView {
      List(AppDestination.allCases, selection: $selection) { destination in
        Label(destination.title, systemImage: destination.systemImageName)
          .tag(destination)
          .accessibilityLabel(destination.accessibilityLabel)
          .accessibilityHint(destination.accessibilityHint)
      }
      .navigationTitle("Ledger Atlas")
      .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
    } detail: {
      destinationPreview
        .animation(
          MotionPolicy.navigationAnimation(reduceMotion: reduceMotion),
          value: selection
        )
    }
    .fileImporter(
      isPresented: $isChoosingLedger, allowedContentTypes: Self.importTypes,
      allowsMultipleSelection: false
    ) { result in
      guard case .success(let urls) = result, let url = urls.first else { return }
      if selection == .importReview || selection == .onboarding {
        let accessing = url.startAccessingSecurityScopedResource()
        guard accessing else {
          recordFlowFailure("Ledger access was not granted.", publishingWidget: .permissionDenied)
          return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        guard
          let sourceTimeZone = try? SourceTimeZone(
            ianaIdentifier: sourceTimeZoneIdentifier)
        else {
          journey.recordFailure("Choose the backup's source time zone before import.")
          return
        }
        do {
          try bookmarkStore.save(url, for: .importSource)
        } catch {
          recordFlowFailure("Import access could not be retained.", publishingWidget: .reopenRequired)
          return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
          UUID().uuidString)
        guard
          (try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)) != nil
        else { return }
        journey.performSelectSource(
          url, stagingDatabaseURL: directory.appendingPathComponent("stage.sqlite"),
          canonicalDatabaseURL: directory.appendingPathComponent("canonical.sqlite"),
          sourceTimeZone: sourceTimeZone)
      } else {
        guard session.open(url, requiresSecurityScope: true) else {
          recordFlowFailure("Ledger access was not granted.", publishingWidget: .permissionDenied)
          return
        }
        journey.openLedger(url)
        guard journey.phase == .imported else {
          session.close()
          recordFlowFailure(
            journey.lastFailure ?? "Ledger could not be opened.", publishingWidget: .reopenRequired)
          return
        }
        do {
          try bookmarkStore.save(url, for: .canonicalLedger)
          guard publishWidget(.ready) else { session.close(); return }
        } catch {
          recordFlowFailure("Ledger access could not be retained.", publishingWidget: .reopenRequired)
        }
      }
    }
    .task {
      switch bookmarkStore.reopen(.canonicalLedger) {
      case .missing:
        _ = publishWidget(.empty)
      case .corrupt:
        recordFlowFailure("Ledger access needs to be selected again.", publishingWidget: .reopenRequired)
      case .stale:
        recordFlowFailure("Ledger access needs to be selected again.", publishingWidget: .reopenRequired)
      case .denied:
        recordFlowFailure("Ledger access was not granted.", publishingWidget: .permissionDenied)
      case .resolved(let url), .renewed(let url):
        guard session.open(url, requiresSecurityScope: true) else {
          recordFlowFailure("Ledger access was not granted.", publishingWidget: .permissionDenied)
          return
        }
        journey.openLedger(url)
        guard journey.phase == .imported else {
          session.close()
          recordFlowFailure(
            journey.lastFailure ?? "Ledger could not be opened.", publishingWidget: .reopenRequired)
          return
        }
        guard publishWidget(.ready) else { session.close(); return }
      }
    }
    .frame(minWidth: 720, minHeight: 480)
  }

  private static var importTypes: [UTType] {
    var types: [UTType] = [.database, .data]
    if let sqlite = UTType(filenameExtension: "sqlite") { types.insert(sqlite, at: 0) }
    if let mmbak = UTType(filenameExtension: "mmbak") { types.insert(mmbak, at: 0) }
    return types
  }

  @discardableResult
  private func publishWidget(_ state: RedactedWidgetProjection.State) -> Bool {
    guard let widgetProjectionPublisher else {
      journey.recordFailure("Widget status could not be published.")
      return false
    }
    do {
      try widgetProjectionPublisher.publish(state)
      return true
    } catch {
      journey.recordFailure("Widget status could not be published.")
      return false
    }
  }

  private func recordFlowFailure(
    _ message: String, publishingWidget state: RedactedWidgetProjection.State
  ) {
    journey.recordFailure(Self.failureMessage(
      widgetPublished: publishWidget(state), flowFailure: message))
  }

  static func failureMessage(widgetPublished: Bool, flowFailure: String) -> String {
    widgetPublished ? flowFailure : "Widget status could not be published. \(flowFailure)"
  }

  @ViewBuilder
  private var destinationPreview: some View {
    if selection != .importReview, selection != .onboarding, session.screen == .loading {
      ProgressView("Opening ledger…")
        .accessibilityLabel("Opening ledger")
    } else if selection != .importReview, selection != .onboarding,
      session.screen == .unavailable
    {
      VStack(alignment: .leading, spacing: 12) {
        Text("Ledger unavailable").font(.largeTitle.bold())
        Text("The selected ledger could not be opened. No previous ledger remains active.")
          .foregroundStyle(.secondary)
        Button("Open…") { isChoosingLedger = true }
      }
      .padding(32)
      .accessibilityElement(children: .contain)
    } else if selection == .importReview || selection == .onboarding {
      VStack(alignment: .leading, spacing: 16) {
        ImportReviewView(summary: journey.phase == .idle ? importReviewSummary : journey.summary)
        if let lastFailure = journey.lastFailure {
          Text(lastFailure)
            .foregroundStyle(.red)
            .accessibilityLabel(lastFailure)
        }
        Picker("Backup source time zone", selection: $sourceTimeZoneIdentifier) {
          Text("Choose source time zone…").tag("")
          ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { identifier in
            Text(identifier).tag(identifier)
          }
        }
        .accessibilityLabel("Backup source time zone")
        .accessibilityHint("Required to preserve the backup's civil date and time meaning.")
        .disabled(journey.isSourceTimeZoneSelectionLocked)
        Button("Choose Money Manager backup…") { isChoosingLedger = true }
          .accessibilityLabel("Choose Money Manager backup")
          .disabled(sourceTimeZoneIdentifier.isEmpty)
        if journey.phase == .reviewing {
          Button("Approve import") {
            journey.performApprove(into: session)
            if journey.lastFailure == nil {
              if let url = journey.ledgerURL {
                do {
                  try bookmarkStore.save(url, for: .canonicalLedger)
                  guard publishWidget(.ready) else { return }
                } catch {
                  recordFlowFailure("Ledger access could not be retained.", publishingWidget: .reopenRequired)
                  return
                }
              }
              selection = .ledger
            }
          }
          .accessibilityLabel("Approve import")
        }
      }
      .id(selection)
    } else if selection == .ledger {
      LedgerView(
        state: session.state, rows: journey.rows(for: .ledger), isEditing: journey.isEditing,
        open: { isChoosingLedger = true },
        lastFailure: journey.lastFailure,
        beginEditing: { try? journey.performBeginEditing() },
        saveAmount: { transactionID, amountLiteral in
          journey.performCorrectAmount(
            transactionID: transactionID, amountLiteral: amountLiteral,
            createdAt: UTCInstant(epochMilliseconds: UTCInstant.currentEpochMilliseconds()))
        },
        addMacTransaction: { amountLiteral in
          journey.performCreateMacTransaction(
            amountLiteral: amountLiteral,
            createdAt: UTCInstant(epochMilliseconds: UTCInstant.currentEpochMilliseconds()))
        }
      )
      .id(selection)
    } else if selection == .backupRestore {
      BackupSurface(
        rows: journey.rows(for: .backupRestore),
        emptyMessage: selection.emptyStateMessage,
        lastFailure: journey.lastFailure,
        open: { isChoosingLedger = true },
        saveBackup: {
          let panel = NSSavePanel()
          panel.allowedContentTypes = [.database, .data]
          panel.nameFieldStringValue = "ledger-atlas-backup.sqlite"
          guard panel.runModal() == .OK, let url = panel.url else { return }
          do {
            try journey.backupCanonicalLedger(to: url)
          } catch {
            journey.recordFailure("Backup could not be saved.")
          }
        }
      )
      .id(selection)
    } else if selection == .accounts {
      AccountsView(state: session.state, rows: journey.rows(for: .accounts)) {
        isChoosingLedger = true
      }
      .id(selection)
    } else if selection == .search {
      SearchSurface(
        rows: journey.rows(for: .search),
        query: journey.searchQuery.textContains ?? journey.searchQuery.noteContains ?? "",
        emptyMessage: selection.emptyStateMessage
      ) { text in
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        journey.setSearch(LedgerSearchQuery(textContains: trimmed.isEmpty ? nil : trimmed))
      } open: {
        isChoosingLedger = true
      }
      .id(selection)
    } else if selection == .insights {
      InsightsSurface(
        rows: journey.rows(for: .insights),
        table: journey.insightTable,
        emptyMessage: selection.emptyStateMessage
      ) { isChoosingLedger = true }
      .id(selection)
    } else {
      DataBackedSurface(
        destination: selection, rows: journey.rows(for: selection),
        emptyMessage: selection.emptyStateMessage
      ) { isChoosingLedger = true }
      .id(selection)
    }
  }
}

private struct SearchSurface: View {
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

private struct InsightsSurface: View {
  let rows: [LedgerJourney.SurfaceRow]
  let table: String
  let emptyMessage: String
  let open: () -> Void

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
      }
      .navigationTitle("Insights")
    }
  }
}

private struct DataBackedSurface: View {
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

private struct BackupSurface: View {
  let rows: [LedgerJourney.SurfaceRow]
  let emptyMessage: String
  let lastFailure: String?
  let open: () -> Void
  let saveBackup: () -> Void

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
      }
    }
    .padding(16)
    .navigationTitle("Backup")
  }
}

private struct LedgerView: View {
  let state: LedgerSession.State
  let rows: [LedgerJourney.SurfaceRow]
  let isEditing: Bool
  let open: () -> Void
  let lastFailure: String?
  let beginEditing: () -> Void
  let saveAmount: (String, String) -> Void
  let addMacTransaction: (String) -> Void
  @State private var selectedID: String?
  @State private var amountLiteral = ""
  @State private var macAmountLiteral = ""

  var body: some View {
    if !rows.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        List(rows, selection: $selectedID) { row in
          VStack(alignment: .leading, spacing: 4) {
            Text(row.title)
            Text(row.detail).font(.caption).foregroundStyle(.secondary)
          }
          .tag(row.id)
        }
        if let lastFailure {
          Text(lastFailure)
            .foregroundStyle(.red)
            .accessibilityLabel(lastFailure)
            .padding(.horizontal, 16)
        }
        if isEditing {
          HStack {
            TextField("Amount", text: $amountLiteral)
            Button("Save") {
              guard let selectedID, !amountLiteral.isEmpty else { return }
              saveAmount(selectedID, amountLiteral)
            }
            .accessibilityLabel("Save amount")
          }
          .padding(.horizontal, 16)
          HStack {
            TextField("Mac amount", text: $macAmountLiteral)
            Button("Add Mac transaction") {
              guard !macAmountLiteral.isEmpty else { return }
              addMacTransaction(macAmountLiteral)
            }
            .accessibilityLabel("Add Mac transaction")
          }
          .padding(.horizontal, 16)
          .padding(.bottom, 12)
        } else {
          Button("Begin editing", action: beginEditing)
            .accessibilityLabel("Begin editing")
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
      }
      .navigationTitle("Ledger")
    } else {
      switch state {
      case .noLedger:
        openPrompt(
          title: "Open a ledger", icon: "folder",
          description: "Choose a Ledger Atlas ledger to view its native transactions.",
          buttonTitle: "Open Ledger…")
      case .loading:
        ProgressView("Opening ledger…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .unavailable:
        openPrompt(
          title: "Ledger unavailable", icon: "exclamationmark.triangle",
          description: "This ledger could not be opened safely.",
          buttonTitle: "Choose another ledger…")
      case .loaded(let snapshot)
      where snapshot.transactions.isEmpty && snapshot.undisplayedImportedEventCount > 0:
        ContentUnavailableView(
          "Imported data is preserved", systemImage: "archivebox",
          description: Text(
            "This ledger has imported records that are not yet displayable in the native ledger."))
      case .loaded(let snapshot) where snapshot.transactions.isEmpty:
        openPrompt(
          title: "No transactions", icon: "list.bullet",
          description: "This native ledger has no transactions yet.",
          buttonTitle: "Open another ledger…")
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

  private func openPrompt(title: String, icon: String, description: String, buttonTitle: String)
    -> some View
  {
    VStack(spacing: 12) {
      Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary)
      Text(title).font(.title2.bold())
      Text(description).foregroundStyle(.secondary)
      Button(buttonTitle, action: open)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(32)
  }
}

private struct AccountsView: View {
  let state: LedgerSession.State
  let rows: [LedgerJourney.SurfaceRow]
  let open: () -> Void

  var body: some View {
    if !rows.isEmpty {
      List(rows) { row in
        VStack(alignment: .leading, spacing: 4) {
          Text(row.title)
          Text(row.detail).font(.caption).foregroundStyle(.secondary)
        }
      }
      .navigationTitle("Accounts")
    } else {
      switch state {
      case .loaded(let snapshot) where !snapshot.accounts.isEmpty:
        List {
          ForEach(snapshot.accounts) { account in
            VStack(alignment: .leading, spacing: 4) {
              Text(account.name)
              Text(account.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
        .navigationTitle("Accounts")
      case .loaded:
        ContentUnavailableView(
          "No accounts", systemImage: "rectangle.stack",
          description: Text("This native ledger has no accounts yet."))
      case .unavailable:
        openPrompt(
          title: "Ledger unavailable", icon: "exclamationmark.triangle",
          description: "Choose a compatible ledger to view its accounts.",
          buttonTitle: "Open Ledger…")
      case .noLedger:
        openPrompt(
          title: "Open a ledger", icon: "folder",
          description: "Choose a Ledger Atlas ledger to view its accounts.",
          buttonTitle: "Open Ledger…")
      case .loading:
        ProgressView("Opening ledger…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  private func openPrompt(title: String, icon: String, description: String, buttonTitle: String)
    -> some View
  {
    VStack(spacing: 12) {
      Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary)
      Text(title).font(.title2.bold())
      Text(description).foregroundStyle(.secondary)
      Button(buttonTitle, action: open)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(32)
  }
}
