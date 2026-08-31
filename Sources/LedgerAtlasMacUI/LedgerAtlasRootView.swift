import AppKit
import CryptoKit
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
  @State private var appLock = LedgerAppLock()
  @State private var journey = LedgerJourney()
  @State private var productSettings = LedgerProductSettings.load()
  @State private var pendingIntent: LedgerIntentRequest?
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
      if appLock.isLocked && selection != .settings {
        LockedSurface(
          lock: appLock,
          unlock: { appLock.unlock(with: $0) },
          biometricUnlock: { await appLock.unlockWithBiometrics() })
      } else {
        destinationPreview
          .animation(
            MotionPolicy.navigationAnimation(reduceMotion: reduceMotion),
            value: selection
          )
      }
    }
    .preferredColorScheme(productSettings.colorScheme)
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
    .onReceive(NotificationCenter.default.publisher(for: LedgerIntentBridge.didEnqueueNotification)) { _ in
      consumePendingIntentIfUnlocked()
    }
    .onChange(of: appLock.isLocked) { _, locked in
      if !locked { consumePendingIntentIfUnlocked() }
    }
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

  private func exportPDFStatement() {
    guard let snapshot = journey.snapshot else {
      journey.recordFailure("Open a ledger before exporting a statement.")
      return
    }
    let unit = snapshot.accounts.first?.currencyUnit
      ?? snapshot.transactions.first?.currentRevision.draft.effects.first?.amount.unitCode
      ?? "USD"
    guard let report = try? LedgerApplication.report(from: snapshot, unitCode: unit) else {
      journey.recordFailure("The report could not be generated.")
      return
    }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType.pdf]
    panel.nameFieldStringValue = "ledger-atlas-statement.pdf"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try LedgerPDFStatementExporter.export(report, to: url)
    } catch {
      journey.recordFailure("The PDF statement could not be saved.")
    }
  }

  private func restoreBackup() {
    let openPanel = NSOpenPanel()
    openPanel.title = "Choose a Ledger Atlas backup"
    openPanel.allowedContentTypes = [.database, .data]
    openPanel.allowsMultipleSelection = false
    openPanel.canChooseDirectories = false
    guard openPanel.runModal() == .OK, let source = openPanel.url else { return }
    guard source.startAccessingSecurityScopedResource() else {
      journey.recordFailure("Backup access was not granted.")
      return
    }
    defer { source.stopAccessingSecurityScopedResource() }
    guard let preview = try? LedgerStore.openReadOnly(at: source).readSnapshot() else {
      journey.recordFailure("The selected backup could not be validated.")
      return
    }
    let alert = NSAlert()
    alert.messageText = "Restore this backup as a new ledger?"
    alert.informativeText =
      "The backup contains \(preview.accounts.count) accounts, \(preview.transactions.count) transactions, and \(preview.categories.count) categories. The original backup stays unchanged."
    alert.addButton(withTitle: "Choose destination")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let savePanel = NSSavePanel()
    savePanel.title = "Restore backup as a new ledger"
    savePanel.prompt = "Restore"
    savePanel.allowedContentTypes = Self.ledgerTypes
    savePanel.nameFieldStringValue = "ledger-atlas-restored.sqlite"
    savePanel.canCreateDirectories = true
    guard savePanel.runModal() == .OK, let destination = savePanel.url else { return }
    guard destination.standardizedFileURL != source.standardizedFileURL else {
      journey.recordFailure("Choose a new destination for the restored ledger.")
      return
    }
    guard destination.startAccessingSecurityScopedResource() else {
      journey.recordFailure("Restore destination access was not granted.")
      return
    }
    defer { destination.stopAccessingSecurityScopedResource() }
    do {
      try journey.restoreCanonicalBackup(from: source, to: destination)
      lifecycleMessage = "Backup restored as a new ledger."
      selection = .ledger
    } catch {
      journey.recordFailure("The backup could not be restored without replacing existing data.")
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
        accounts: journey.snapshot?.accounts ?? [], categories: journey.snapshot?.categories ?? [],
        splitPurchases: splitPurchases,
        splitTransactionIDs: splitTransactionIDs,
        intentRequest: pendingIntent,
        consumeIntent: { pendingIntent = nil },
        open: openLedger,
        lifecycleMessage: lifecycleMessage,
        lastFailure: journey.lastFailure,
        beginEditing: { try? journey.performBeginEditing() },
        saveAmount: { transactionID, amountLiteral in
          journey.performCorrectAmount(
            transactionID: transactionID, amountLiteral: amountLiteral,
            createdAt: UTCInstant(epochMilliseconds: UTCInstant.currentEpochMilliseconds()))
        },
        tombstone: { transactionID in
          do {
            try journey.tombstoneTransaction(
              transactionID: transactionID,
              createdAt: UTCInstant(epochMilliseconds: UTCInstant.currentEpochMilliseconds()))
          } catch { journey.recordFailure("Transaction could not be closed.") }
        },
        copy: { transactionID in
          do {
            _ = try journey.copyTransaction(
              transactionID: transactionID,
              createdAt: UTCInstant(epochMilliseconds: UTCInstant.currentEpochMilliseconds()))
          } catch { journey.recordFailure("Transaction could not be copied.") }
        },
        addMacTransaction: { amountLiteral in
          journey.performCreateMacTransaction(
            amountLiteral: amountLiteral,
            createdAt: UTCInstant(epochMilliseconds: UTCInstant.currentEpochMilliseconds()))
        },
        createTransaction: { amount, kind, accountID, categoryID, note in
          do {
            _ = try journey.createNativeTransaction(
              amountLiteral: amount, kind: kind, accountID: accountID,
              categoryID: categoryID, note: note,
              createdAt: UTCInstant(epochMilliseconds: UTCInstant.currentEpochMilliseconds()))
          } catch {
            journey.recordFailure("Transaction could not be saved.")
          }
        },
        createSplit: { draft in
          do {
            _ = try journey.createSplit(
              draft, createdAt: UTCInstant(epochMilliseconds: UTCInstant.currentEpochMilliseconds()))
          } catch {
            journey.recordFailure("Split purchase could not be saved.")
          }
        }
      )
      .id(selection)
    } else if selection == .receipts {
      ReceiptSurface()
        .id(selection)
    } else if selection == .localAccess {
      LocalAccessSurface(
        accountCount: journey.snapshot?.accounts.count ?? 0,
        transactionCount: journey.snapshot?.transactions.count ?? 0)
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
        },
        restoreBackup: restoreBackup
      )
      .id(selection)
    } else if selection == .transfers {
      TransferSurface(
        rows: journey.rows(for: .transfers),
        accounts: journey.snapshot?.accounts ?? [], intentRequest: pendingIntent,
        consumeIntent: { pendingIntent = nil }, isEditing: journey.isEditing,
        lastFailure: lifecycleMessage ?? journey.lastFailure,
        beginEditing: { try? journey.performBeginEditing() },
        createTransfer: { sourceID, destinationID, sourceAmount, destinationAmount, rate, feeAmount, feeAccountID in
          do {
            _ = try journey.createNativeTransfer(
              sourceAccountID: sourceID, destinationAccountID: destinationID,
              sourceAmountLiteral: sourceAmount, destinationAmountLiteral: destinationAmount,
              rateLiteral: rate, feeAmountLiteral: feeAmount, feeAccountID: feeAccountID,
              createdAt: UTCInstant(epochMilliseconds: UTCInstant.currentEpochMilliseconds()))
          } catch {
            journey.recordFailure("Transfer could not be saved.")
          }
        }
      )
      .id(selection)
      } else if selection == .accounts {
      AccountsView(
        state: session.state, rows: journey.rows(for: .accounts),
        accounts: journey.snapshot?.accounts ?? [], groups: journey.snapshot?.accountGroups ?? [],
        isEditing: journey.isEditing, lastFailure: lifecycleMessage ?? journey.lastFailure,
        beginEditing: { try? journey.performBeginEditing() },
        saveAccount: { account in
          do { try journey.updateAccount(account) }
          catch { journey.recordFailure("Account could not be saved.") }
        },
        saveGroup: { group in
          do { try journey.updateAccountGroup(group) }
          catch { journey.recordFailure("Account group could not be saved.") }
        },
        createAccount: { account in
          do { try journey.createAccount(account) }
          catch { journey.recordFailure("Account could not be created.") }
        },
        createGroup: { group in
          do { try journey.createAccountGroup(group) }
          catch { journey.recordFailure("Account group could not be created.") }
        },
        open: openLedger)
      .id(selection)
    } else if selection == .categories {
      CategoriesView(
        state: session.state, rows: journey.rows(for: .categories),
        categories: journey.snapshot?.categories ?? [], isEditing: journey.isEditing,
        lastFailure: lifecycleMessage ?? journey.lastFailure,
        beginEditing: { try? journey.performBeginEditing() },
        saveCategory: { category in
          do { try journey.updateCategory(category) }
          catch { journey.recordFailure("Category could not be saved.") }
        },
        createCategory: { category in
          do { try journey.createCategory(category) }
          catch { journey.recordFailure("Category could not be created.") }
        },
        open: openLedger)
      .id(selection)
    } else if selection == .recurrence {
      RecurrenceView(
        state: session.state, rules: journey.snapshot?.recurrenceRules ?? [],
        accounts: journey.snapshot?.accounts ?? [], categories: journey.snapshot?.categories ?? [],
        isEditing: journey.isEditing, lastFailure: lifecycleMessage ?? journey.lastFailure,
        beginEditing: { try? journey.performBeginEditing() },
        onCreate: { rule in
          do { try journey.createRecurrence(rule) }
          catch { journey.recordFailure("Recurrence rule could not be saved.") }
        },
        onUpdate: { rule, scope in
          do { try journey.updateRecurrence(rule, scope: scope) }
          catch { journey.recordFailure("Recurrence rule could not be updated.") }
        },
        onGenerate: { rule, end in
          do {
            try journey.generateOccurrences(
              rule, through: end,
              createdAt: UTCInstant(epochMilliseconds: UTCInstant.currentEpochMilliseconds()))
          } catch { journey.recordFailure("Recurrence occurrences could not be generated.") }
        },
        open: openLedger)
      .id(selection)
    } else if selection == .installments {
      InstallmentsView(
        state: session.state,
        plans: journey.snapshot?.installmentPlans ?? [], accounts: journey.snapshot?.accounts ?? [],
        categories: journey.snapshot?.categories ?? [], isEditing: journey.isEditing,
        lastFailure: lifecycleMessage ?? journey.lastFailure,
        beginEditing: { try? journey.performBeginEditing() },
        onCreate: { plan, occurredAt in
          do {
            _ = try journey.createInstallmentPlan(
              plan, occurredAt: occurredAt,
              createdAt: UTCInstant(epochMilliseconds: UTCInstant.currentEpochMilliseconds()))
          } catch { journey.recordFailure("Installment plan could not be saved.") }
        },
        onUpdate: { plan in
          do { try journey.updateInstallmentPlan(plan) }
          catch { journey.recordFailure("Installment plan could not be updated.") }
        },
        open: openLedger)
      .id(selection)
    } else if selection == .budgets {
      BudgetsView(
        state: session.state, budgets: journey.snapshot?.budgets ?? [],
        categories: journey.snapshot?.categories ?? [], accounts: journey.snapshot?.accounts ?? [],
        isEditing: journey.isEditing, lastFailure: lifecycleMessage ?? journey.lastFailure,
        beginEditing: { try? journey.performBeginEditing() },
        onCreate: { budget in
          do { try journey.createBudget(budget) }
          catch { journey.recordFailure("Budget could not be saved.") }
        },
        onUpdate: { budget in
          do { try journey.updateBudget(budget) }
          catch { journey.recordFailure("Budget could not be updated.") }
        },
        open: openLedger)
      .id(selection)
    } else if selection == .settings {
      SettingsSurface(
        lock: appLock, settings: $productSettings,
        lockNow: lockApp,
        reducedMotion: reduceMotion,
        exportDiagnostics: exportDiagnostics)
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
      ) { openLedger() } exportPDF: {
        exportPDFStatement()
      }
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

  private func lockApp() {
    guard appLock.hasPasscode else { return }
    appLock.lock()
    session.close()
    journey.closeLedger()
    _ = publishWidget(.reopenRequired)
  }

  private func consumePendingIntentIfUnlocked() {
    guard !appLock.isLocked, pendingIntent == nil,
      let request = LedgerIntentBridge.consume()
    else { return }
    switch request.kind {
    case .addExpense, .addIncome:
      pendingIntent = request
      selection = .ledger
    case .addTransfer:
      lifecycleMessage = "Transfer request received. Open Transfers and choose New transfer to review it."
      selection = .transfers
    case .createBackup:
      lifecycleMessage = "Backup request received. Choose a destination to create it."
      selection = .backupRestore
    case .openBudgets:
      selection = .budgets
    }
  }

  private func exportDiagnostics() {
    guard let snapshot = journey.snapshot else {
      journey.recordFailure("Open a ledger before exporting diagnostics.")
      return
    }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "ledger-atlas-diagnostics.json"
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    do {
      try LedgerDiagnosticsWriter.write(.init(snapshot: snapshot), to: destination)
      lifecycleMessage = "Diagnostics exported without financial values or paths."
    } catch {
      journey.recordFailure("Diagnostics could not be exported.")
    }
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
  let restoreBackup: () -> Void

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
  let accounts: [LedgerAccount]
  let categories: [LedgerCategory]
  let splitPurchases: [LedgerSplitPurchase]
  let splitTransactionIDs: Set<String>
  let intentRequest: LedgerIntentRequest?
  let consumeIntent: () -> Void
  let open: () -> Void
  let lifecycleMessage: String?
  let lastFailure: String?
  let beginEditing: () -> Void
  let saveAmount: (String, String) -> Void
  let tombstone: (String) -> Void
  let copy: (String) -> Void
  let addMacTransaction: (String) -> Void
  let createTransaction: (String, LedgerTransactionKind, String, String?, String?) -> Void
  let createSplit: (LedgerSplitDraft) -> Void
  @State private var selectedID: String?
  @State private var amountLiteral = ""
  @State private var macAmountLiteral = ""
  @State private var showingTransactionForm = false
  @State private var showingSplitForm = false

  var body: some View {
    Group {
      if !rows.isEmpty {
        VStack(alignment: .leading, spacing: 12) {
        List(selection: $selectedID) {
          ForEach(rows.filter { !splitTransactionIDs.contains($0.id) }) { row in
            VStack(alignment: .leading, spacing: 4) {
              Text(row.title)
              Text(row.detail).font(.caption).foregroundStyle(.secondary)
            }
            .tag(row.id)
            .contextMenu {
              Button("Copy transaction") { copy(row.id) }
              Button("Close transaction", role: .destructive) { tombstone(row.id) }
            }
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
            Button("New transaction") { showingTransactionForm = true }
              .accessibilityLabel("New income or expense")
            Button("New split purchase") { showingSplitForm = true }
              .accessibilityLabel("New split purchase")
          }
          .padding(.horizontal, 16)
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
            Button("Copy selected") {
              guard let selectedID else { return }
              copy(selectedID)
            }
            .disabled(selectedID == nil)
            Button("Close selected", role: .destructive) {
              guard let selectedID else { return }
              tombstone(selectedID)
            }
            .disabled(selectedID == nil)
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
          VStack(spacing: 12) {
            ContentUnavailableView(
              "No transactions", systemImage: "list.bullet",
              description: Text(
                lifecycleMessage ?? "This native ledger has no transactions yet."))
            if isEditing {
              HStack {
                Button("New transaction") { showingTransactionForm = true }
                  .accessibilityLabel("New income or expense")
                Button("New split purchase") { showingSplitForm = true }
                  .accessibilityLabel("New split purchase")
              }
            } else {
              Button("Begin editing", action: beginEditing)
                .accessibilityLabel("Begin editing")
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    .sheet(isPresented: $showingTransactionForm) {
      NativeTransactionForm(
        accounts: accounts, categories: categories, intent: intentRequest,
        onSave: { amount, kind, accountID, categoryID, note in
          createTransaction(amount, kind, accountID, categoryID, note)
          if intentRequest != nil { consumeIntent() }
        })
    }
    .sheet(isPresented: $showingSplitForm) {
      SplitPurchaseForm(accounts: accounts, categories: categories, onSave: createSplit)
    }
    .onAppear { presentIntentIfNeeded() }
    .onChange(of: intentRequest) { _, _ in presentIntentIfNeeded() }
  }

  private func presentIntentIfNeeded() {
    guard let intentRequest, !showingTransactionForm else { return }
    guard intentRequest.kind == .addExpense || intentRequest.kind == .addIncome else { return }
    showingTransactionForm = true
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

private struct TransferSurface: View {
  let rows: [LedgerJourney.SurfaceRow]
  let accounts: [LedgerAccount]
  let intentRequest: LedgerIntentRequest?
  let consumeIntent: () -> Void
  let isEditing: Bool
  let lastFailure: String?
  let beginEditing: () -> Void
  let createTransfer: (String, String, String, String?, String?, String?, String?) -> Void
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
        onSave: { sourceID, destinationID, sourceAmount, destinationAmount, rate, feeAmount, feeAccountID in
          createTransfer(
            sourceID, destinationID, sourceAmount, destinationAmount, rate, feeAmount, feeAccountID)
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

private struct NativeTransferForm: View {
  let accounts: [LedgerAccount]
  let intent: LedgerIntentRequest?
  let onSave: (String, String, String, String?, String?, String?, String?) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var sourceAccountID = ""
  @State private var destinationAccountID = ""
  @State private var sourceAmount = ""
  @State private var destinationAmount = ""
  @State private var rate = ""
  @State private var feeAmount = ""
  @State private var feeAccountID: String?

  init(
    accounts: [LedgerAccount], intent: LedgerIntentRequest? = nil,
    onSave: @escaping (String, String, String, String?, String?, String?, String?) -> Void
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
          TextField("Exchange rate", text: $rate)
            .accessibilityHint("Required when the account currencies differ.")
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
              sourceAccountID.isEmpty || destinationAccountID.isEmpty
                || sourceAccountID == destinationAccountID || sourceAmount.isEmpty
                || (needsConversion && (destinationAmount.isEmpty || rate.isEmpty))
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
    rate = ""
  }

  private func save() {
    onSave(
      sourceAccountID, destinationAccountID, sourceAmount,
      needsConversion ? destinationAmount : nil, needsConversion ? rate : nil,
      feeAmount.isEmpty ? nil : feeAmount, feeAmount.isEmpty ? nil : feeAccountID)
    dismiss()
  }
}

private struct NativeTransactionForm: View {
  let accounts: [LedgerAccount]
  let categories: [LedgerCategory]
  let intent: LedgerIntentRequest?
  let onSave: (String, LedgerTransactionKind, String, String?, String?) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var amount = ""
  @State private var kind: LedgerTransactionKind = .expense
  @State private var accountID = ""
  @State private var categoryID: String?
  @State private var note = ""

  init(
    accounts: [LedgerAccount], categories: [LedgerCategory], intent: LedgerIntentRequest? = nil,
    onSave: @escaping (String, LedgerTransactionKind, String, String?, String?) -> Void
  ) {
    self.accounts = accounts
    self.categories = categories
    self.intent = intent
    self.onSave = onSave
    _amount = State(initialValue: intent?.amountLiteral ?? "")
    _kind = State(initialValue: intent?.kind == .addIncome ? .income : .expense)
    _note = State(initialValue: intent?.note ?? "")
  }

  private var availableCategories: [LedgerCategory] {
    categories.filter {
      $0.lifecycle == .active && !$0.hidden && $0.kind.accepts(kind)
    }.sorted { $0.name < $1.name }
  }

  var body: some View {
    Form {
      if accounts.isEmpty {
        ContentUnavailableView(
          "No accounts", systemImage: "rectangle.stack",
          description: Text("Create an account before entering a transaction."))
      } else {
        TextField("Amount", text: $amount)
        Picker("Type", selection: $kind) {
          Text("Expense").tag(LedgerTransactionKind.expense)
          Text("Income").tag(LedgerTransactionKind.income)
        }
        Picker("Account", selection: $accountID) {
          ForEach(accounts.filter { $0.lifecycle == .active }, id: \.id) { account in
            Text("\(account.name) (\(account.currencyUnit))").tag(account.id)
          }
        }
        Picker("Category", selection: $categoryID) {
          Text("No category").tag(String?.none)
          ForEach(availableCategories, id: \.id) { category in
            Text(category.name).tag(Optional(category.id))
          }
        }
        TextField("Note (optional)", text: $note)
        HStack {
          Button("Cancel", role: .cancel) { dismiss() }
          Spacer()
          Button("Save") { save() }
            .disabled(amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || accountID.isEmpty)
        }
      }
    }
    .padding(20)
    .frame(width: 460)
    .onAppear {
      if accountID.isEmpty { accountID = accounts.first(where: { $0.lifecycle == .active })?.id ?? "" }
    }
    .onChange(of: kind) { _, _ in
      if let categoryID, !availableCategories.contains(where: { $0.id == categoryID }) {
        self.categoryID = nil
      }
    }
    .accessibilityElement(children: .contain)
  }

  private func save() {
    let cleanAmount = amount.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
    onSave(cleanAmount, kind, accountID, categoryID, cleanNote.isEmpty ? nil : cleanNote)
    dismiss()
  }
}

private struct SplitLineInput: Identifiable {
  let id: Int
  var amount = ""
  var categoryID = ""
  var description = ""
}

private struct SplitPurchaseForm: View {
  let accounts: [LedgerAccount]
  let categories: [LedgerCategory]
  let onSave: (LedgerSplitDraft) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var parentAmount = ""
  @State private var accountID = ""
  @State private var note = ""
  @State private var lines = [SplitLineInput(id: 0), SplitLineInput(id: 1), SplitLineInput(id: 2)]

  private var availableCategories: [LedgerCategory] {
    categories.filter { $0.lifecycle == .active && !$0.hidden && $0.kind == .expense }
      .sorted { $0.name < $1.name }
  }

  var body: some View {
    Form {
      if accounts.isEmpty || availableCategories.count < 2 {
        ContentUnavailableView(
          "Split purchase needs setup", systemImage: "square.split.2x1",
          description: Text("Create an account and at least two active expense categories first."))
      } else {
        TextField("Purchase total", text: $parentAmount)
        Picker("Account", selection: $accountID) {
          ForEach(accounts.filter { $0.lifecycle == .active }, id: \.id) { account in
            Text("\(account.name) (\(account.currencyUnit))").tag(account.id)
          }
        }
        Section("Categories") {
          ForEach($lines) { $line in
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Text("Line \(line.id + 1)").font(.headline)
                Spacer()
                TextField("Amount", text: $line.amount)
                  .frame(width: 110)
              }
              Picker("Category", selection: $line.categoryID) {
                Text("Choose category…").tag("")
                ForEach(availableCategories, id: \.id) { category in
                  Text(category.name).tag(category.id)
                }
              }
              TextField("Description (optional)", text: $line.description)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Split line \(line.id + 1)")
          }
        }
        TextField("Purchase note (optional)", text: $note)
        HStack {
          Button("Cancel", role: .cancel) { dismiss() }
          Spacer()
          Button("Save split purchase") { save() }
            .disabled(parentAmount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || accountID.isEmpty)
        }
      }
    }
    .padding(20)
    .frame(width: 560)
    .onAppear {
      if accountID.isEmpty { accountID = accounts.first(where: { $0.lifecycle == .active })?.id ?? "" }
    }
    .accessibilityElement(children: .contain)
  }

  private func save() {
    let cleanParent = parentAmount.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let origin = try? LedgerOrigin.macNative(),
      let localKey = Self.digest("split:\(UUID().uuidString)"),
      let purchaseID = try? StableLedgerID.transaction(origin: origin, localKey: localKey),
      let account = accounts.first(where: { $0.id == accountID }),
      let total = try? CurrencyAmount(unitCode: account.currencyUnit, amount: ExactDecimal(cleanParent)),
      let occurredAt = try? LedgerJourney.nativeTemporal(
        for: UTCInstant(epochMilliseconds: UTCInstant.currentEpochMilliseconds()))
    else { return }
    var builtLines: [LedgerSplitLine] = []
    for input in lines where !input.amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let cleanAmount = input.amount.trimmingCharacters(in: .whitespacesAndNewlines)
      let cleanDescription = input.description.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !input.categoryID.isEmpty,
        let amount = try? CurrencyAmount(
          unitCode: account.currencyUnit, amount: ExactDecimal(cleanAmount)),
        let lineID = try? StableLedgerID.splitLine(
          origin: origin, localKey: Self.digest("\(purchaseID):\(input.id)") ?? localKey),
        let line = try? LedgerSplitLine(
          id: lineID, amount: amount, categoryID: input.categoryID,
          description: cleanDescription.isEmpty ? nil : cleanDescription, displayOrder: input.id)
      else { return }
      builtLines.append(line)
    }
    guard builtLines.count >= 2,
      let draft = try? LedgerSplitDraft(
        id: purchaseID, accountID: accountID, parentAmount: total, lines: builtLines,
        occurredAt: occurredAt, note: cleanNote.isEmpty ? nil : cleanNote, origin: origin)
    else { return }
    onSave(draft)
    dismiss()
  }

  private static func digest(_ value: String) -> String? {
    let result = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    return CanonicalIdentifier.isValid(result) ? result : nil
  }
}

private struct AccountsView: View {
  let state: LedgerSession.State
  let rows: [LedgerJourney.SurfaceRow]
  let accounts: [LedgerAccount]
  let groups: [LedgerAccountGroup]
  let isEditing: Bool
  let lastFailure: String?
  let beginEditing: () -> Void
  let saveAccount: (LedgerAccount) -> Void
  let saveGroup: (LedgerAccountGroup) -> Void
  let createAccount: (LedgerAccount) -> Void
  let createGroup: (LedgerAccountGroup) -> Void
  let open: () -> Void
  @State private var showingAccountForm = false
  @State private var showingGroupForm = false
  @State private var editingAccount: LedgerAccount?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if !accounts.isEmpty {
        List {
          ForEach(groups.sorted { $0.displayOrder == $1.displayOrder ? $0.name < $1.name : $0.displayOrder < $1.displayOrder }, id: \.id) { group in
            Section {
              ForEach(Self.sortedAccounts(accounts.filter { $0.groupID == group.id }), id: \.id) { account in
                AccountRow(account: account, isEditing: isEditing, save: saveAccount) {
                  editingAccount = $0
                }
              }
              if !accounts.contains(where: { $0.groupID == group.id }) {
                Text("No accounts in this group").foregroundStyle(.secondary)
              }
            } header: {
              AccountGroupHeader(group: group, isEditing: isEditing, save: saveGroup)
            }
          }
          Section("Ungrouped") {
            let ungrouped = Self.sortedAccounts(accounts.filter { $0.groupID == nil })
            if ungrouped.isEmpty {
              Text("No ungrouped accounts").foregroundStyle(.secondary)
            } else {
              ForEach(ungrouped, id: \.id) { account in
                AccountRow(account: account, isEditing: isEditing, save: saveAccount) {
                  editingAccount = $0
                }
              }
            }
          }
        }
      } else if !rows.isEmpty {
        List(rows) { row in
          VStack(alignment: .leading, spacing: 4) {
            Text(row.title)
            Text(row.detail).font(.caption).foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel("\(row.title), \(row.detail)")
        }
      } else {
        emptyContent
      }
      if let lastFailure {
        Text(lastFailure)
          .foregroundStyle(.red)
          .accessibilityLabel(lastFailure)
      }
      HStack {
        if isEditing {
          Button("New account") { showingAccountForm = true }
            .accessibilityLabel("New account")
          Button("New group") { showingGroupForm = true }
            .accessibilityLabel("New account group")
        } else if !accounts.isEmpty || !rows.isEmpty {
          Button("Begin editing", action: beginEditing)
            .accessibilityLabel("Begin editing accounts")
        } else {
          Button("Open Ledger…", action: open)
        }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 12)
    }
    .navigationTitle("Accounts")
    .sheet(isPresented: $showingAccountForm) {
      AccountForm(groups: groups, onSave: { account in
        createAccount(account)
        showingAccountForm = false
      })
    }
    .sheet(isPresented: $showingGroupForm) {
      AccountGroupForm(onSave: { group in
        createGroup(group)
        showingGroupForm = false
      })
    }
    .sheet(isPresented: Binding(
      get: { editingAccount != nil }, set: { if !$0 { editingAccount = nil } })) {
      if let editingAccount {
        AccountEditForm(account: editingAccount, groups: groups) { revised in
          saveAccount(revised)
          self.editingAccount = nil
        }
      }
    }
  }

  @ViewBuilder
  private var emptyContent: some View {
    switch state {
    case .loaded:
      ContentUnavailableView(
        "No accounts", systemImage: "rectangle.stack",
        description: Text(isEditing ? "Create an account or group to start organizing balances." : "Begin editing to manage accounts."))
    case .unavailable:
      EmptyLedgerPrompt(title: "Ledger unavailable", description: "Choose a compatible ledger to view its accounts.", guidance: .unavailable, failure: lastFailure, buttonTitle: "Open Ledger…", open: open)
    case .noLedger:
      EmptyLedgerPrompt(title: "Open a ledger", description: "Choose a Ledger Atlas ledger to view its accounts.", guidance: .noLedger, failure: lastFailure, buttonTitle: "Open Ledger…", open: open)
    case .loading:
      ProgressView("Opening ledger…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private static func revise(_ group: LedgerAccountGroup, lifecycle: LedgerLifecycleState) -> LedgerAccountGroup? {
    try? LedgerAccountGroup(id: group.id, name: group.name, displayOrder: group.displayOrder, lifecycle: lifecycle)
  }

  private static func sortedAccounts(_ accounts: [LedgerAccount]) -> [LedgerAccount] {
    accounts.sorted {
      $0.displayOrder == $1.displayOrder ? $0.name < $1.name : $0.displayOrder < $1.displayOrder
    }
  }
}

private struct AccountRow: View {
  let account: LedgerAccount
  let isEditing: Bool
  let save: (LedgerAccount) -> Void
  let edit: (LedgerAccount) -> Void

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        Text(account.name)
        Text("\(account.currencyUnit) · \(account.variant.rawValue) · \(account.lifecycle.rawValue)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if account.hidden { Label("Hidden", systemImage: "eye.slash").font(.caption) }
      if !account.includeInTotals { Label("Excluded from totals", systemImage: "minus.circle").font(.caption) }
      if account.lifecycle == .tombstoned { Label("Closed", systemImage: "archivebox").font(.caption) }
      Menu("Actions") {
        Button("Edit account") { edit(account) }
        Button(account.hidden ? "Show account" : "Hide account") {
          update(hidden: !account.hidden)
        }
        Button(account.includeInTotals ? "Exclude from totals" : "Include in totals") {
          update(includeInTotals: !account.includeInTotals)
        }
        Button(account.lifecycle == .active ? "Close account" : "Restore account") {
          update(lifecycle: account.lifecycle == .active ? .tombstoned : .active)
        }
      }
      .disabled(!isEditing)
      .accessibilityLabel("Actions for \(account.name)")
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(account.name), \(account.currencyUnit), \(account.lifecycle.rawValue)")
  }

  private func update(
    name: String? = nil, lifecycle: LedgerLifecycleState? = nil, hidden: Bool? = nil,
    includeInTotals: Bool? = nil
  ) {
    guard let revised = try? LedgerAccount(
      id: account.id, name: name ?? account.name, currencyUnit: account.currencyUnit,
      origin: account.origin, lifecycle: lifecycle ?? account.lifecycle, groupID: account.groupID,
      displayOrder: account.displayOrder, hidden: hidden ?? account.hidden,
      includeInTotals: includeInTotals ?? account.includeInTotals, variant: account.variant)
    else { return }
    save(revised)
  }
}

private struct AccountEditForm: View {
  let account: LedgerAccount
  let groups: [LedgerAccountGroup]
  let onSave: (LedgerAccount) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var groupID: String?
  @State private var displayOrder: String
  @State private var hidden: Bool
  @State private var includeInTotals: Bool
  @State private var variant: LedgerAccountVariant

  init(account: LedgerAccount, groups: [LedgerAccountGroup], onSave: @escaping (LedgerAccount) -> Void) {
    self.account = account
    self.groups = groups
    self.onSave = onSave
    _name = State(initialValue: account.name)
    _groupID = State(initialValue: account.groupID)
    _displayOrder = State(initialValue: String(account.displayOrder))
    _hidden = State(initialValue: account.hidden)
    _includeInTotals = State(initialValue: account.includeInTotals)
    _variant = State(initialValue: account.variant)
  }

  var body: some View {
    Form {
      TextField("Account name", text: $name)
      Text("Currency: \(account.currencyUnit)").font(.caption).foregroundStyle(.secondary)
      Picker("Group", selection: $groupID) {
        Text("No group").tag(String?.none)
        ForEach(groups.filter { $0.lifecycle == .active }, id: \.id) { Text($0.name).tag(Optional($0.id)) }
      }
      TextField("Display order", text: $displayOrder)
      Picker("Account type", selection: $variant) {
        ForEach(LedgerAccountVariant.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
      }
      Toggle("Hidden", isOn: $hidden)
      Toggle("Include in totals", isOn: $includeInTotals)
      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
        Spacer()
        Button("Save") { save() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Int(displayOrder) == nil)
      }
    }
    .padding(20).frame(width: 420)
  }

  private func save() {
    guard let order = Int(displayOrder), order >= 0,
      let revised = try? LedgerAccount(
        id: account.id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
        currencyUnit: account.currencyUnit, origin: account.origin, lifecycle: account.lifecycle,
        groupID: groupID, displayOrder: order, hidden: hidden,
        includeInTotals: includeInTotals, variant: variant)
    else { return }
    onSave(revised)
    dismiss()
  }
}

private struct AccountGroupHeader: View {
  let group: LedgerAccountGroup
  let isEditing: Bool
  let save: (LedgerAccountGroup) -> Void

  var body: some View {
    HStack {
      Text(group.name)
      if group.lifecycle == .tombstoned {
        Text("Closed").font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if isEditing {
        Button(group.lifecycle == .active ? "Close group" : "Restore group") {
          guard let revised = try? LedgerAccountGroup(
            id: group.id, name: group.name, displayOrder: group.displayOrder,
            lifecycle: group.lifecycle == .active ? .tombstoned : .active)
          else { return }
          save(revised)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("\(group.lifecycle == .active ? "Close" : "Restore") account group \(group.name)")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Account group \(group.name), \(group.lifecycle.rawValue)")
  }
}

private struct AccountForm: View {
  let groups: [LedgerAccountGroup]
  let onSave: (LedgerAccount) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var currency = "USD"
  @State private var groupID: String?
  @State private var variant: LedgerAccountVariant = .standard
  @State private var includeInTotals = true

  var body: some View {
    Form {
      TextField("Account name", text: $name)
      TextField("Currency code", text: $currency)
        .textCase(.uppercase)
      Picker("Group", selection: $groupID) {
        Text("No group").tag(String?.none)
        ForEach(groups.filter { $0.lifecycle == .active }, id: \.id) { group in
          Text(group.name).tag(Optional(group.id))
        }
      }
      Picker("Account type", selection: $variant) {
        ForEach(LedgerAccountVariant.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
      }
      Toggle("Include in totals", isOn: $includeInTotals)
      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
        Spacer()
        Button("Create") { create() }
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || currency.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 420)
    .accessibilityElement(children: .contain)
  }

  private func create() {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let unit = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard let origin = try? LedgerOrigin.macNative(),
      let id = try? StableLedgerID.account(origin: origin, localKey: Self.generatedID()),
      let account = try? LedgerAccount(
      id: id, name: trimmedName, currencyUnit: unit, origin: origin,
        groupID: groupID, includeInTotals: includeInTotals, variant: variant)
    else { return }
    onSave(account)
    dismiss()
  }

  private static func generatedID() -> String {
    SHA256.hash(data: Data("ledger-atlas/account/\(UUID().uuidString)".utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

private struct AccountGroupForm: View {
  let onSave: (LedgerAccountGroup) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""

  var body: some View {
    Form {
      TextField("Group name", text: $name)
      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
        Spacer()
        Button("Create") { create() }
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 360)
  }

  private func create() {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let id = Self.generatedID(), let group = try? LedgerAccountGroup(id: id, name: trimmedName) else { return }
    onSave(group)
    dismiss()
  }

  private static func generatedID() -> String? {
    let value = SHA256.hash(data: Data("ledger-atlas/account-group/\(UUID().uuidString)".utf8)).map { String(format: "%02x", $0) }.joined()
    return CanonicalIdentifier.isValid(value) ? value : nil
  }
}

private struct CategoriesView: View {
  let state: LedgerSession.State
  let rows: [LedgerJourney.SurfaceRow]
  let categories: [LedgerCategory]
  let isEditing: Bool
  let lastFailure: String?
  let beginEditing: () -> Void
  let saveCategory: (LedgerCategory) -> Void
  let createCategory: (LedgerCategory) -> Void
  let open: () -> Void
  @State private var showingCategoryForm = false
  @State private var editingCategory: LedgerCategory?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if !categories.isEmpty {
        List {
          ForEach(categories.filter { $0.parentID == nil }.sorted(by: Self.categoryOrder), id: \.id) { category in
            CategoryTreeRow(
              category: category, allCategories: categories, isEditing: isEditing, save: saveCategory,
              edit: { editingCategory = $0 })
          }
        }
      } else if !rows.isEmpty {
        List(rows) { row in
          VStack(alignment: .leading, spacing: 4) {
            Text(row.title)
            Text(row.detail).font(.caption).foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel("\(row.title), \(row.detail)")
        }
      } else {
        switch state {
        case .loaded:
          ContentUnavailableView("No categories", systemImage: "tag", description: Text(isEditing ? "Create a category to classify transactions." : "Begin editing to manage categories."))
        case .unavailable:
          EmptyLedgerPrompt(title: "Ledger unavailable", description: "Choose a compatible ledger to view its categories.", guidance: .unavailable, failure: lastFailure, buttonTitle: "Open Ledger…", open: open)
        case .noLedger:
          EmptyLedgerPrompt(title: "Open a ledger", description: "Choose a Ledger Atlas ledger to view its categories.", guidance: .noLedger, failure: lastFailure, buttonTitle: "Open Ledger…", open: open)
        case .loading:
          ProgressView("Opening ledger…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      if let lastFailure {
        Text(lastFailure).foregroundStyle(.red).accessibilityLabel(lastFailure)
      }
      HStack {
        if isEditing {
          Button("New category") { showingCategoryForm = true }.accessibilityLabel("New category")
        } else if !categories.isEmpty || !rows.isEmpty {
          Button("Begin editing", action: beginEditing).accessibilityLabel("Begin editing categories")
        } else {
          Button("Open Ledger…", action: open)
        }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 12)
    }
    .navigationTitle("Categories")
    .sheet(isPresented: $showingCategoryForm) {
      CategoryForm(categories: categories, onSave: { category in
        createCategory(category)
        showingCategoryForm = false
      })
    }
    .sheet(isPresented: Binding(
      get: { editingCategory != nil }, set: { if !$0 { editingCategory = nil } })) {
      if let editingCategory {
        CategoryEditForm(category: editingCategory, categories: categories) { revised in
          saveCategory(revised)
          self.editingCategory = nil
        }
      }
    }
  }

  private static func categoryOrder(_ lhs: LedgerCategory, _ rhs: LedgerCategory) -> Bool {
    lhs.displayOrder == rhs.displayOrder ? lhs.name < rhs.name : lhs.displayOrder < rhs.displayOrder
  }
}

private struct CategoryTreeRow: View {
  let category: LedgerCategory
  let allCategories: [LedgerCategory]
  let isEditing: Bool
  let save: (LedgerCategory) -> Void
  let edit: (LedgerCategory) -> Void
  @State private var expanded = true

  private var children: [LedgerCategory] {
    allCategories.filter { $0.parentID == category.id }.sorted {
      $0.displayOrder == $1.displayOrder ? $0.name < $1.name : $0.displayOrder < $1.displayOrder
    }
  }

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      ForEach(children, id: \.id) { child in
        CategoryTreeRow(
          category: child, allCategories: allCategories, isEditing: isEditing, save: save, edit: edit)
      }
    } label: {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(category.name)
          Text("\(category.kind.rawValue) · \(category.lifecycle.rawValue)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if category.hidden { Label("Hidden", systemImage: "eye.slash").font(.caption) }
        Menu("Actions") {
          Button("Edit category") { edit(category) }
          Button(category.hidden ? "Show category" : "Hide category") { update(hidden: !category.hidden) }
          Button(category.lifecycle == .active ? "Close category" : "Restore category") {
            update(lifecycle: category.lifecycle == .active ? .tombstoned : .active)
          }
        }
        .disabled(!isEditing)
        .accessibilityLabel("Actions for \(category.name)")
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("\(category.name), \(category.kind.rawValue), \(category.lifecycle.rawValue)")
    }
  }

  private func update(lifecycle: LedgerLifecycleState? = nil, hidden: Bool? = nil) {
    guard let revised = try? LedgerCategory(
      id: category.id, name: category.name, kind: category.kind, origin: category.origin,
      lifecycle: lifecycle ?? category.lifecycle, parentID: category.parentID,
      displayOrder: category.displayOrder, hidden: hidden ?? category.hidden)
    else { return }
    save(revised)
  }
}

private struct CategoryEditForm: View {
  let category: LedgerCategory
  let categories: [LedgerCategory]
  let onSave: (LedgerCategory) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var parentID: String?
  @State private var displayOrder: String
  @State private var hidden: Bool

  init(category: LedgerCategory, categories: [LedgerCategory], onSave: @escaping (LedgerCategory) -> Void) {
    self.category = category
    self.categories = categories
    self.onSave = onSave
    _name = State(initialValue: category.name)
    _parentID = State(initialValue: category.parentID)
    _displayOrder = State(initialValue: String(category.displayOrder))
    _hidden = State(initialValue: category.hidden)
  }

  var body: some View {
    Form {
      TextField("Category name", text: $name)
      Picker("Parent", selection: $parentID) {
        Text("Top level").tag(String?.none)
        ForEach(availableParents, id: \.id) { Text($0.name).tag(Optional($0.id)) }
      }
      TextField("Display order", text: $displayOrder)
      Toggle("Hidden", isOn: $hidden)
      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
        Spacer()
        Button("Save") { save() }
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Int(displayOrder) == nil)
      }
    }
    .padding(20).frame(width: 420)
  }

  private var availableParents: [LedgerCategory] {
    let excluded = descendantIDs(of: category.id).union([category.id])
    return categories.filter {
      $0.lifecycle == .active && !$0.hidden && !excluded.contains($0.id)
    }.sorted { ($0.displayOrder, $0.name) < ($1.displayOrder, $1.name) }
  }

  private func descendantIDs(of id: String) -> Set<String> {
    var result: Set<String> = []
    var pending = [id]
    while let current = pending.popLast() {
      for child in categories where child.parentID == current && result.insert(child.id).inserted {
        pending.append(child.id)
      }
    }
    return result
  }

  private func save() {
    guard let order = Int(displayOrder), order >= 0,
      let revised = try? LedgerCategory(
        id: category.id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: category.kind,
        origin: category.origin, lifecycle: category.lifecycle, parentID: parentID,
        displayOrder: order, hidden: hidden)
    else { return }
    onSave(revised)
    dismiss()
  }
}

private struct CategoryForm: View {
  let categories: [LedgerCategory]
  let onSave: (LedgerCategory) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var kind: LedgerCategoryKind = .expense
  @State private var parentID: String?

  var body: some View {
    Form {
      TextField("Category name", text: $name)
      Picker("Kind", selection: $kind) {
        ForEach(LedgerCategoryKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
      }
      Picker("Parent", selection: $parentID) {
        Text("Top level").tag(String?.none)
        ForEach(categories.filter { $0.lifecycle == .active && !$0.hidden }.sorted { $0.name < $1.name }, id: \.id) { category in
          Text(category.name).tag(Optional(category.id))
        }
      }
      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
        Spacer()
        Button("Create") { create() }
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 420)
  }

  private func create() {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let origin = try? LedgerOrigin.macNative(),
      let id = try? StableLedgerID.category(origin: origin, localKey: Self.generatedID()),
      let category = try? LedgerCategory(id: id, name: trimmedName, kind: kind, origin: origin, parentID: parentID)
    else { return }
    onSave(category)
    dismiss()
  }

  private static func generatedID() -> String {
    SHA256.hash(data: Data("ledger-atlas/category/\(UUID().uuidString)".utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

private struct EmptyLedgerPrompt: View {
  let title: String
  let description: String
  let guidance: LedgerLifecycleGuidance
  let failure: String?
  let buttonTitle: String
  let open: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "folder").font(.largeTitle).foregroundStyle(.secondary)
      Text(title).font(.title2.bold())
      Text(description).foregroundStyle(.secondary)
      LedgerLifecycleGuidanceView(guidance: guidance, failure: failure)
      Button(buttonTitle, action: open)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(32)
  }
}
