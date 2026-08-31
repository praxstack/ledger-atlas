import AppKit
import LedgerCore
import LedgerStore
import SwiftUI
import UniformTypeIdentifiers

package enum LedgerLifecycleOperation: Equatable, Sendable {
  case create, open

  package var retryButtonTitle: String { self == .create ? "Create Ledger…" : "Open Ledger…" }
  package var retryAccessibilityLabel: String { self == .create ? "Create Ledger" : "Open Ledger" }
}
package typealias LedgerLifecycleRunner =
  @Sendable (LedgerLifecycleOperation, URL) async throws
  -> LedgerStoreLifecycle.Result
package typealias LedgerSnapshotReader =
  @Sendable (LedgerStore) throws
  -> LedgerStore.LedgerReadSnapshot

package enum LedgerLifecycleGuidance: Sendable {
  case noLedger, unavailable

  package func text(retrying operation: LedgerLifecycleOperation? = nil) -> String {
    if let operation {
      return operation == .create
        ? "Choose Create Ledger to retry. Recovery is reported only after the ledger is validated."
        : "Choose Open Ledger to retry. Recovery is reported only after the ledger is validated."
    }
    return switch self {
    case .noLedger:
      "Choose Open Ledger to select a ledger. If an earlier attempt failed, select it again to retry."
    case .unavailable:
      "Choose Open Ledger to retry. Recovery is reported only after the ledger is validated."
    }
  }
}

package struct LedgerLifecycleOutcome: Equatable, Sendable {
  package enum Kind: Equatable, Sendable {
    case cancelled, missingBookmark, created, opened, upgraded, failed
  }

  package let kind: Kind
  package let recoveryImageExists: Bool
  package let message: String?
  package let retryOperation: LedgerLifecycleOperation?

  package init(
    kind: Kind, recoveryImageExists: Bool, message: String?,
    retryOperation: LedgerLifecycleOperation? = nil
  ) {
    self.kind = kind
    self.recoveryImageExists = recoveryImageExists
    self.message = message
    self.retryOperation = retryOperation
  }
}

private struct LedgerLifecycleCompletion: @unchecked Sendable {
  // Exclusive ownership transfers from detached lifecycle work to the main actor.
  let store: LedgerStore
  let disposition: LedgerStoreLifecycle.Disposition
  let recoveryImageURL: URL?

  init(_ result: LedgerStoreLifecycle.Result) {
    store = result.store
    disposition = result.disposition
    recoveryImageURL = result.recoveryImageURL
  }
}

private struct LedgerLifecyclePreparation: @unchecked Sendable {
  let completion: LedgerLifecycleCompletion
  let snapshot: LedgerStore.LedgerReadSnapshot?
  let snapshotReadFailed: Bool

  init(_ result: LedgerStoreLifecycle.Result, snapshotReader: LedgerSnapshotReader) {
    completion = LedgerLifecycleCompletion(result)
    do {
      snapshot = try snapshotReader(result.store)
      snapshotReadFailed = false
    } catch {
      snapshot = nil
      snapshotReadFailed = true
    }
  }
}

public struct LedgerAtlasRootView: View {
  package static let createLedgerActionLabel = "Create Ledger"
  package static let openLedgerActionLabel = "Open Ledger"
  package static let createLedgerPanelMessage = "Choose where to save the new ledger."
  package static let openLedgerPanelMessage = "Choose a Ledger Atlas ledger."

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var selection: AppDestination
  @State private var session = LedgerSession()
  @State private var journey = LedgerJourney()
  @State private var isChoosingImportSource = false
  @State private var lifecycleMessage: String?
  @State private var lifecycleRetryOperation: LedgerLifecycleOperation?
  @State private var lifecycleGeneration = 0
  @State private var lifecycleTask: Task<Void, Never>?
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
      forSecurityApplicationGroupIdentifier: RedactedWidgetProjectionStore.appGroupIdentifier
    )
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
    .toolbar {
      ToolbarItemGroup {
        Button("Create Ledger…", action: createLedger)
          .accessibilityLabel(Self.createLedgerActionLabel)
          .accessibilityHint("Opens a save panel for a new Ledger Atlas ledger.")
          .keyboardShortcut("n", modifiers: [.command, .shift])
        Button("Open Ledger…", action: openLedger)
          .accessibilityLabel(Self.openLedgerActionLabel)
          .accessibilityHint("Opens a file panel for an existing Ledger Atlas ledger.")
          .keyboardShortcut("o", modifiers: .command)
      }
    }
    .fileImporter(
      isPresented: $isChoosingImportSource, allowedContentTypes: Self.importTypes,
      allowsMultipleSelection: false
    ) { result in
      guard case .success(let urls) = result, let url = urls.first else { return }
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
    }
    .task { startSavedLedgerReopen() }
    .onDisappear { lifecycleTask?.cancel() }
    .frame(minWidth: 720, minHeight: 480)
  }

  private static var importTypes: [UTType] {
    var types: [UTType] = [.database, .data]
    if let sqlite = UTType(filenameExtension: "sqlite") { types.insert(sqlite, at: 0) }
    if let mmbak = UTType(filenameExtension: "mmbak") { types.insert(mmbak, at: 0) }
    return types
  }

  private static var ledgerTypes: [UTType] {
    if let sqlite = UTType(filenameExtension: "sqlite") { return [sqlite, .database] }
    return [.database]
  }

  private func createLedger() {
    let panel = NSSavePanel()
    panel.title = Self.createLedgerActionLabel
    panel.prompt = "Create"
    panel.message = Self.createLedgerPanelMessage
    panel.nameFieldLabel = "Ledger file:"
    panel.nameFieldStringValue = "ledger-atlas.sqlite"
    panel.allowedContentTypes = Self.ledgerTypes
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    performLedgerSelection(.create, url: panel.runModal() == .OK ? panel.url : nil)
  }

  private func openLedger() {
    let panel = NSOpenPanel()
    panel.title = Self.openLedgerActionLabel
    panel.prompt = "Open"
    panel.message = Self.openLedgerPanelMessage
    panel.allowedContentTypes = Self.ledgerTypes
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    performLedgerSelection(.open, url: panel.runModal() == .OK ? panel.url : nil)
  }

  private func performLedgerSelection(_ operation: LedgerLifecycleOperation, url: URL?) {
    guard url != nil else { return }
    lifecycleTask?.cancel()
    lifecycleGeneration &+= 1
    let generation = lifecycleGeneration
    lifecycleTask = Task {
      let outcome = await Self.performLedgerSelection(
        operation, url: url, bookmarkStore: bookmarkStore,
        widgetPublisher: widgetProjectionPublisher, journey: journey, session: session,
        scopeStarter: { $0.startAccessingSecurityScopedResource() },
        scopeStopper: { $0.stopAccessingSecurityScopedResource() },
        isCurrent: { lifecycleGeneration == generation })
      guard lifecycleGeneration == generation else {
        recordSupersededPublication(outcome)
        return
      }
      lifecycleMessage = outcome.message
      lifecycleRetryOperation = outcome.retryOperation
      if [.created, .opened, .upgraded].contains(outcome.kind) { selection = .ledger }
    }
  }

  private func startSavedLedgerReopen() {
    lifecycleTask?.cancel()
    lifecycleGeneration &+= 1
    let generation = lifecycleGeneration
    lifecycleTask = Task {
      let outcome = await Self.reopenSavedLedger(
        bookmarkStore: bookmarkStore, widgetPublisher: widgetProjectionPublisher,
        journey: journey, session: session,
        scopeStarter: { $0.startAccessingSecurityScopedResource() },
        scopeStopper: { $0.stopAccessingSecurityScopedResource() },
        isCurrent: { lifecycleGeneration == generation })
      guard lifecycleGeneration == generation else {
        recordSupersededPublication(outcome)
        return
      }
      lifecycleMessage = outcome.message
      lifecycleRetryOperation = outcome.retryOperation
      if [.opened, .upgraded].contains(outcome.kind) { selection = .ledger }
    }
  }

  private func retryLedger(_ operation: LedgerLifecycleOperation) {
    switch operation {
    case .create: createLedger()
    case .open: openLedger()
    }
  }

  private func recordSupersededPublication(_ outcome: LedgerLifecycleOutcome) {
    guard let message = Self.supersededPublicationMessage(for: outcome) else { return }
    lifecycleMessage = message
    lifecycleRetryOperation = .open
    journey.recordFailure(message)
  }

  @discardableResult
  private func publishWidget(_ state: RedactedWidgetProjection.State) -> Bool {
    Self.publishWidget(
      state, publisher: widgetProjectionPublisher, journey: journey, session: session)
  }

  @discardableResult
  static func publishWidget(
    _ state: RedactedWidgetProjection.State, publisher: RedactedWidgetProjectionPublisher?,
    journey: LedgerJourney, session: LedgerSession,
    closeLedgerOnFailure: Bool = true
  ) -> Bool {
    guard let publisher else {
      journey.recordFailure("Widget status could not be published.")
      if closeLedgerOnFailure {
        session.close()
        journey.closeLedger()
      }
      return false
    }
    do {
      try publisher.publish(state)
      return true
    } catch {
      journey.recordFailure("Widget status could not be published.")
      if closeLedgerOnFailure {
        session.close()
        journey.closeLedger()
      }
      return false
    }
  }

  private func recordFlowFailure(
    _ message: String, publishingWidget state: RedactedWidgetProjection.State
  ) {
    journey.recordFailure(
      Self.failureMessage(
        widgetPublished: publishWidget(state), flowFailure: message))
  }

  static func failureMessage(widgetPublished: Bool, flowFailure: String) -> String {
    widgetPublished ? flowFailure : "Widget status could not be published. \(flowFailure)"
  }

  package static func supersededPublicationMessage(
    for outcome: LedgerLifecycleOutcome
  ) -> String? {
    switch outcome.kind {
    case .created:
      "An earlier Create Ledger request finished and created a ledger. Choose Open Ledger to select the ledger you want to use."
    case .upgraded:
      "An earlier Open Ledger request finished and upgraded its ledger. A validated recovery image is available. Choose Open Ledger to select the ledger you want to use."
    case .failed where outcome.retryOperation == .open:
      outcome.message.map { "An earlier ledger request finished: \($0)" }
    default:
      nil
    }
  }

  package static func backupFailureMessage(for error: any Swift.Error) -> String {
    if error as? LedgerStore.Error == .backupPublicationCompleted {
      return
        "Backup was published, but durability or final validation did not finish. Verify the destination before retrying."
    }
    return "Backup could not be saved."
  }

  private static func permissionDeniedMessage(for operation: LedgerLifecycleOperation) -> String {
    operation == .create
      ? "Ledger access was not granted to create the ledger. Choose Create Ledger to retry."
      : "Ledger access was not granted to open the ledger. Choose Open Ledger to retry."
  }

  private static func outcome(
    for completion: LedgerLifecycleCompletion
  ) -> LedgerLifecycleOutcome {
    let kind: LedgerLifecycleOutcome.Kind =
      switch completion.disposition {
      case .created: .created
      case .opened: .opened
      case .upgraded: .upgraded
      }
    let recoveryExists = completion.recoveryImageURL != nil
    return .init(
      kind: kind, recoveryImageExists: recoveryExists,
      message: recoveryExists
        ? "Ledger upgraded. A validated recovery image is available." : nil)
  }

  private static func publicationFailureMessage(
    operation: LedgerLifecycleOperation, phase: LedgerStoreLifecycle.PublicationPhase,
    recoveryImageExists: Bool
  ) -> String {
    if operation == .open, phase == .currentPublished, !recoveryImageExists {
      return
        "Ledger upgrade was published, but the recovery image failed validation. The current ledger was not rolled back. Repair or replace the recovery image, then choose Open Ledger to retry."
    }
    let recoveryMessage =
      recoveryImageExists
      ? "A validated recovery image is available."
      : "No recovery image passed validation."
    return switch (operation, phase) {
    case (.create, .currentPublished):
      "Ledger was created, but it could not be reopened. Choose Open Ledger to continue."
    case (_, .recoveryPublished):
      "Ledger upgrade did not finish. \(recoveryMessage) Choose Open Ledger to retry."
    case (_, .currentPublished):
      "Ledger upgrade was published, but opening or cleanup did not finish. \(recoveryMessage) Choose Open Ledger to retry."
    case (_, .reconciledCurrent):
      "Ledger upgrade recovery finished, but the ledger could not be reopened. \(recoveryMessage) Choose Open Ledger to retry."
    }
  }

  @MainActor
  package static func performLedgerSelection(
    _ operation: LedgerLifecycleOperation, url: URL?,
    bookmarkStore: SecurityScopedBookmarkStore,
    widgetPublisher: RedactedWidgetProjectionPublisher?, journey: LedgerJourney,
    session: LedgerSession, scopeStarter: (URL) -> Bool,
    scopeStopper: (URL) -> Void,
    lifecycle: @escaping LedgerLifecycleRunner =
      runLedgerLifecycle,
    snapshotReader: @escaping LedgerSnapshotReader = { try $0.readSnapshot() },
    isCurrent: @escaping @MainActor () -> Bool = { true }
  ) async -> LedgerLifecycleOutcome {
    guard let url else {
      return .init(kind: .cancelled, recoveryImageExists: false, message: nil)
    }
    return await performLedgerLifecycle(
      operation, at: url, bookmarkStore: bookmarkStore, widgetPublisher: widgetPublisher,
      journey: journey, session: session, scopeStarter: scopeStarter,
      scopeStopper: scopeStopper, lifecycle: lifecycle, snapshotReader: snapshotReader,
      isCurrent: isCurrent)
  }

  @MainActor
  package static func performLedgerLifecycle(
    _ operation: LedgerLifecycleOperation, at url: URL,
    bookmarkStore: SecurityScopedBookmarkStore,
    widgetPublisher: RedactedWidgetProjectionPublisher?, journey: LedgerJourney,
    session: LedgerSession, scopeStarter: (URL) -> Bool,
    scopeStopper: (URL) -> Void,
    lifecycle: @escaping LedgerLifecycleRunner =
      runLedgerLifecycle,
    snapshotReader: @escaping LedgerSnapshotReader = { try $0.readSnapshot() },
    isCurrent: @escaping @MainActor () -> Bool = { true }
  ) async -> LedgerLifecycleOutcome {
    guard isCurrent() else {
      return .init(kind: .cancelled, recoveryImageExists: false, message: nil)
    }
    guard scopeStarter(url) else {
      session.close()
      journey.closeLedger()
      let message = failureMessage(
        widgetPublished: publishWidget(
          .permissionDenied, publisher: widgetPublisher, journey: journey, session: session),
        flowFailure: permissionDeniedMessage(for: operation))
      journey.recordFailure(message)
      return .init(
        kind: .failed, recoveryImageExists: false, message: message, retryOperation: operation)
    }
    defer { scopeStopper(url) }
    session.close()
    journey.closeLedger()
    var completedLifecycle: LedgerLifecycleCompletion?
    do {
      let lifecycleTask = Task.detached {
        let result = try await lifecycle(operation, url)
        return LedgerLifecyclePreparation(result, snapshotReader: snapshotReader)
      }
      let preparation = try await withTaskCancellationHandler {
        try await lifecycleTask.value
      } onCancel: {
        lifecycleTask.cancel()
      }
      completedLifecycle = preparation.completion
      // Once the core crosses its publication/reconciliation point of no return, report that
      // completed truth even if this UI request was superseded. The generation guard owned by
      // the view prevents the stale result from replacing the newer active session.
      guard !Task.isCancelled, isCurrent() else {
        return outcome(for: preparation.completion)
      }
      guard let snapshot = preparation.snapshot, !preparation.snapshotReadFailed else {
        throw LedgerLifecycleFlowError.snapshotValidationFailed
      }
      journey.adoptValidatedLedger(preparation.completion.store, snapshot: snapshot, at: url)
      guard session.openValidated(url, snapshot: snapshot, requiresSecurityScope: true) else {
        throw LedgerLifecycleFlowError.permissionDenied
      }
      try bookmarkStore.save(url, for: .canonicalLedger)
      let widgetPublished = publishWidget(
        .ready, publisher: widgetPublisher, journey: journey, session: session,
        closeLedgerOnFailure: false)
      let completed = outcome(for: preparation.completion)
      guard !widgetPublished else { return completed }
      return .init(
        kind: completed.kind, recoveryImageExists: completed.recoveryImageExists,
        message: [completed.message, "Widget status could not be published."]
          .compactMap { $0 }.joined(separator: " "))
    } catch {
      let publication: (phase: LedgerStoreLifecycle.PublicationPhase, recovery: Bool)?
      if case .publicationCompleted(let phase, let recovery) =
        error as? LedgerStoreLifecycle.Error
      {
        publication = (phase, recovery)
      } else {
        publication = nil
      }
      if Task.isCancelled, publication == nil {
        return .init(kind: .cancelled, recoveryImageExists: false, message: nil)
      }
      guard isCurrent() else {
        if let publication {
          return .init(
            kind: .failed, recoveryImageExists: publication.recovery,
            message: publicationFailureMessage(
              operation: operation, phase: publication.phase,
              recoveryImageExists: publication.recovery),
            retryOperation: .open)
        }
        return .init(kind: .cancelled, recoveryImageExists: false, message: nil)
      }
      session.close()
      journey.closeLedger()
      let flowError = error as? LedgerLifecycleFlowError
      let permissionDenied = flowError == .permissionDenied
      let message: String
      let retryOperation: LedgerLifecycleOperation
      if let publication {
        retryOperation = .open
        message = publicationFailureMessage(
          operation: operation, phase: publication.phase,
          recoveryImageExists: publication.recovery)
      } else if let completedLifecycle {
        retryOperation = .open
        if flowError == .snapshotValidationFailed {
          message =
            switch completedLifecycle.disposition {
            case .created:
              "Ledger was created, but its contents could not be validated. Choose Open Ledger to inspect or retry."
            case .opened:
              "Ledger was opened, but its contents could not be validated. Choose Open Ledger to retry."
            case .upgraded:
              "Ledger was upgraded, but its contents could not be validated. A validated recovery image is available. Choose Open Ledger to retry."
            }
        } else {
          message =
            switch completedLifecycle.disposition {
            case .created:
              "Ledger was created, but access could not be retained. Choose Open Ledger to continue."
            case .opened:
              "Ledger was opened, but access could not be retained. Choose Open Ledger to retry."
            case .upgraded:
              "Ledger was upgraded, but access could not be retained. A validated recovery image is available. Choose Open Ledger to retry."
            }
        }
      } else {
        retryOperation = operation
        message =
          permissionDenied
          ? permissionDeniedMessage(for: operation)
          : operation == .create
            ? "Ledger could not be created. Choose Create Ledger to retry."
            : "Ledger could not be opened. Choose Open Ledger to retry."
      }
      let reportedMessage = failureMessage(
        widgetPublished: publishWidget(
          permissionDenied ? .permissionDenied : .reopenRequired,
          publisher: widgetPublisher, journey: journey, session: session),
        flowFailure: message)
      journey.recordFailure(reportedMessage)
      return .init(
        kind: .failed,
        recoveryImageExists: publication?.recovery ?? (completedLifecycle?.recoveryImageURL != nil),
        message: reportedMessage, retryOperation: retryOperation)
    }
  }

  @MainActor
  package static func reopenSavedLedger(
    bookmarkStore: SecurityScopedBookmarkStore,
    widgetPublisher: RedactedWidgetProjectionPublisher?, journey: LedgerJourney,
    session: LedgerSession, scopeStarter: (URL) -> Bool,
    scopeStopper: (URL) -> Void,
    lifecycle: @escaping LedgerLifecycleRunner =
      runLedgerLifecycle,
    isCurrent: @escaping @MainActor () -> Bool = { true }
  ) async -> LedgerLifecycleOutcome {
    guard isCurrent() else {
      return .init(kind: .cancelled, recoveryImageExists: false, message: nil)
    }
    switch bookmarkStore.reopen(.canonicalLedger) {
    case .missing:
      _ = publishWidget(.empty, publisher: widgetPublisher, journey: journey, session: session)
      return .init(kind: .missingBookmark, recoveryImageExists: false, message: nil)
    case .resolved(let url), .renewed(let url), .stale(let url):
      return await performLedgerLifecycle(
        .open, at: url, bookmarkStore: bookmarkStore, widgetPublisher: widgetPublisher,
        journey: journey, session: session, scopeStarter: scopeStarter,
        scopeStopper: scopeStopper, lifecycle: lifecycle, isCurrent: isCurrent)
    case .denied(let url):
      return await performLedgerLifecycle(
        .open, at: url, bookmarkStore: bookmarkStore, widgetPublisher: widgetPublisher,
        journey: journey, session: session, scopeStarter: { _ in false },
        scopeStopper: { _ in }, lifecycle: lifecycle, isCurrent: isCurrent)
    case .corrupt:
      session.close()
      journey.closeLedger()
      let message = failureMessage(
        widgetPublished: publishWidget(
          .reopenRequired, publisher: widgetPublisher, journey: journey, session: session),
        flowFailure: "Ledger access needs to be selected again. Choose Open Ledger to retry.")
      journey.recordFailure(message)
      return .init(
        kind: .failed, recoveryImageExists: false, message: message, retryOperation: .open)
    }
  }

  @ViewBuilder
  private var destinationPreview: some View {
    if selection != .importReview, selection != .onboarding, session.screen == .loading {
      ProgressView("Opening ledger…")
        .accessibilityLabel("Opening ledger")
    } else if selection != .importReview, selection != .onboarding,
      session.screen == .noLedger, lifecycleMessage != nil || journey.lastFailure != nil
    {
      LedgerLifecycleClosedSessionView(
        title: "Ledger unavailable", guidance: .noLedger,
        failure: lifecycleMessage ?? journey.lastFailure,
        retryOperation: lifecycleRetryOperation ?? .open, retry: retryLedger)
    } else if selection != .importReview, selection != .onboarding, session.screen == .unavailable {
      LedgerLifecycleClosedSessionView(
        title: "Ledger unavailable", guidance: .unavailable,
        failure: lifecycleMessage ?? journey.lastFailure,
        retryOperation: lifecycleRetryOperation ?? .open, retry: retryLedger)
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
        Button("Choose Money Manager backup…") { isChoosingImportSource = true }
          .accessibilityLabel("Choose Money Manager backup")
          .disabled(sourceTimeZoneIdentifier.isEmpty)
        if journey.phase == .reviewing {
          Button("Approve import") {
            journey.performApprove(into: session)
            if journey.lastFailure == nil {
              if let url = journey.ledgerURL {
                do {
                  try bookmarkStore.save(url, for: .canonicalLedger)
                  if !Self.publishWidget(
                    .ready, publisher: widgetProjectionPublisher, journey: journey,
                    session: session, closeLedgerOnFailure: false)
                  {
                    lifecycleMessage = "Widget status could not be published."
                  }
                } catch {
                  recordFlowFailure(
                    "Ledger access could not be retained.", publishingWidget: .reopenRequired)
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
        splitPurchases: splitPurchases,
        splitTransactionIDs: splitTransactionIDs,
        open: openLedger,
        lifecycleMessage: lifecycleMessage,
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
        open: openLedger,
        saveBackup: {
          let panel = NSSavePanel()
          panel.allowedContentTypes = [.database, .data]
          panel.nameFieldStringValue = "ledger-atlas-backup.sqlite"
          guard panel.runModal() == .OK, let url = panel.url else { return }
          do {
            try journey.backupCanonicalLedger(to: url)
          } catch {
            journey.recordFailure(Self.backupFailureMessage(for: error))
          }
        }
      )
      .id(selection)
    } else if selection == .accounts {
      AccountsView(
        state: session.state, rows: journey.rows(for: .accounts),
        lastFailure: lifecycleMessage ?? journey.lastFailure
      ) {
        openLedger()
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
        openLedger()
      }
      .id(selection)
    } else if selection == .insights {
      InsightsSurface(
        rows: journey.rows(for: .insights),
        table: journey.insightTable,
        emptyMessage: selection.emptyStateMessage
      ) { openLedger() }
      .id(selection)
    } else {
      DataBackedSurface(
        destination: selection, rows: journey.rows(for: selection),
        emptyMessage: selection.emptyStateMessage
      ) { openLedger() }
      .id(selection)
    }
  }

  private var splitPurchases: [LedgerSplitPurchase] {
    guard let snapshot = journey.snapshot else { return [] }
    return (try? LedgerApplication.splitPurchases(from: snapshot)) ?? []
  }

  private var splitTransactionIDs: Set<String> {
    guard let snapshot = journey.snapshot else { return [] }
    return Set(
      snapshot.transactions.filter { transaction in
        transaction.links.contains { $0.kind == .split }
      }.map(\.id))
  }
}

private enum LedgerLifecycleFlowError: Error {
  case permissionDenied
  case snapshotValidationFailed
}

private func runLedgerLifecycle(_ operation: LedgerLifecycleOperation, at url: URL) async throws
  -> LedgerStoreLifecycle.Result
{
  switch operation {
  case .create: try LedgerStoreLifecycle.create(at: url)
  case .open: try LedgerStoreLifecycle.open(at: url)
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

private struct LedgerLifecycleGuidanceView: View {
  let guidance: LedgerLifecycleGuidance
  let failure: String?
  let retryOperation: LedgerLifecycleOperation?

  init(
    guidance: LedgerLifecycleGuidance, failure: String?,
    retryOperation: LedgerLifecycleOperation? = nil
  ) {
    self.guidance = guidance
    self.failure = failure
    self.retryOperation = retryOperation
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(guidance.text(retrying: retryOperation)).foregroundStyle(.secondary)
      if let failure {
        Text(failure).foregroundStyle(.red)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      [guidance.text(retrying: retryOperation), failure].compactMap { $0 }.joined(separator: " ")
    )
    .accessibilityHint("Use the available action to select or retry a ledger.")
  }
}

private struct LedgerLifecycleClosedSessionView: View {
  let title: String
  let guidance: LedgerLifecycleGuidance
  let failure: String?
  let retryOperation: LedgerLifecycleOperation
  let retry: (LedgerLifecycleOperation) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title).font(.largeTitle.bold())
      LedgerLifecycleGuidanceView(
        guidance: guidance, failure: failure, retryOperation: retryOperation)
      Button(retryOperation.retryButtonTitle) { retry(retryOperation) }
        .accessibilityLabel(retryOperation.retryAccessibilityLabel)
    }
    .padding(32)
    .accessibilityElement(children: .contain)
  }
}

private struct LedgerView: View {
  let state: LedgerSession.State
  let rows: [LedgerJourney.SurfaceRow]
  let isEditing: Bool
  let splitPurchases: [LedgerSplitPurchase]
  let splitTransactionIDs: Set<String>
  let open: () -> Void
  let lifecycleMessage: String?
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
        List(selection: $selectedID) {
          ForEach(rows.filter { !splitTransactionIDs.contains($0.id) }) { row in
            VStack(alignment: .leading, spacing: 4) {
              Text(row.title)
              Text(row.detail).font(.caption).foregroundStyle(.secondary)
            }
            .tag(row.id)
          }
          ForEach(splitPurchases, id: \.id) { purchase in
            DisclosureGroup {
              ForEach(purchase.lines, id: \.id) { line in
                VStack(alignment: .leading, spacing: 2) {
                  Text(line.description ?? "Split line")
                  Text("Category \(line.categoryID) · \(line.amount.amount.rawLiteral) \(line.amount.unitCode)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                  "\(line.description ?? "Split line"), category \(line.categoryID), \(line.amount.amount.rawLiteral) \(line.amount.unitCode)"
                )
              }
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text("Split purchase")
                Text("\(purchase.parentAmount.amount.rawLiteral) \(purchase.parentAmount.unitCode) · \(purchase.lines.count) categories")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            .accessibilityLabel(
              "Split purchase, \(purchase.parentAmount.amount.rawLiteral) \(purchase.parentAmount.unitCode), \(purchase.lines.count) categories"
            )
          }
        }
        if let lifecycleMessage {
          Text(lifecycleMessage)
            .foregroundStyle(.secondary)
            .accessibilityLabel(lifecycleMessage)
            .padding(.horizontal, 16)
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
        openPrompt(
          title: "No transactions", icon: "list.bullet",
          description: lifecycleMessage ?? "This native ledger has no transactions yet.",
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

  private func openPrompt(
    title: String, icon: String, description: String, buttonTitle: String,
    guidance: LedgerLifecycleGuidance? = nil, failure: String? = nil
  )
    -> some View
  {
    VStack(spacing: 12) {
      Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary)
      Text(title).font(.title2.bold())
      Text(description).foregroundStyle(.secondary)
      if let guidance { LedgerLifecycleGuidanceView(guidance: guidance, failure: failure) }
      Button(buttonTitle, action: open)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(32)
  }
}

private struct AccountsView: View {
  let state: LedgerSession.State
  let rows: [LedgerJourney.SurfaceRow]
  let lastFailure: String?
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
          buttonTitle: "Open Ledger…", guidance: .unavailable, failure: lastFailure)
      case .noLedger:
        openPrompt(
          title: "Open a ledger", icon: "folder",
          description: "Choose a Ledger Atlas ledger to view its accounts.",
          buttonTitle: "Open Ledger…", guidance: .noLedger, failure: lastFailure)
      case .loading:
        ProgressView("Opening ledger…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  private func openPrompt(
    title: String, icon: String, description: String, buttonTitle: String,
    guidance: LedgerLifecycleGuidance? = nil, failure: String? = nil
  )
    -> some View
  {
    VStack(spacing: 12) {
      Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary)
      Text(title).font(.title2.bold())
      Text(description).foregroundStyle(.secondary)
      if let guidance { LedgerLifecycleGuidanceView(guidance: guidance, failure: failure) }
      Button(buttonTitle, action: open)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(32)
  }
}
