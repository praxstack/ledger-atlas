import AppKit
import CryptoKit
import LedgerCore
import LedgerStore
import SwiftUI
import UniformTypeIdentifiers

public struct LedgerAtlasRootView: View {
  package static let createLedgerActionLabel = "Create Ledger"
  package static let openLedgerActionLabel = "Open Ledger"
  package static let createLedgerPanelMessage =
    "Name the new ledger. Ledger Atlas keeps it in its own storage; use Backup to save copies anywhere."
  package static let openLedgerPanelMessage =
    "Choose a Ledger Atlas ledger. A ledger from elsewhere is copied into Ledger Atlas; the original is not changed."

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var selection: AppDestination
  @State private var session: LedgerSession
  @State private var appLock: LedgerAppLock
  @State private var journey = LedgerJourney()
  @State private var portal = LedgerPortalController()
  @State private var productSettings: LedgerProductSettings
  /// macOS Reduce Motion, or always on when Settings says so.
  private var effectiveReduceMotion: Bool {
    productSettings.reduceMotion(systemReduceMotion: reduceMotion)
  }
  @State private var pendingIntent: LedgerIntentRequest?
  @State private var isChoosingImportSource = false
  @State private var lifecycleMessage: String?
  @State private var lifecycleRetryOperation: LedgerLifecycleOperation?
  @State private var lifecycleGeneration = 0
  @State private var lifecycleTask: Task<Void, Never>?
  @State private var sourceTimeZoneIdentifier = ""
  private let bookmarkStore: SecurityScopedBookmarkStore
  private let intentConsumer: () -> LedgerIntentRequest?
  private let widgetProjectionPublisher: RedactedWidgetProjectionPublisher?
  private let importReviewSummary: ImportReviewSummary
  /// Security-scope access for a ledger URL. Tests pass `{ _ in true }` to open a temporary
  /// ledger outside app storage.
  private let scopeStarter: (URL) -> Bool
  private let scopeStopper: (URL) -> Void

  public init(
    initialSelection: AppDestination = .defaultSelection,
    importReviewSummary: ImportReviewSummary? = nil
  ) {
    self.init(
      initialSelection: initialSelection, importReviewSummary: importReviewSummary,
      appLock: LedgerAppLock(), productSettings: .load(),
      bookmarkStore: SecurityScopedBookmarkStore(),
      widgetProjectionPublisher: FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: RedactedWidgetProjectionStore.appGroupIdentifier
      ).map { RedactedWidgetProjectionPublisher(store: .init(containerURL: $0)) },
      intentConsumer: { LedgerIntentBridge.consume() })
  }

  package init(
    initialSelection: AppDestination = .defaultSelection,
    importReviewSummary: ImportReviewSummary? = nil,
    appLock: LedgerAppLock,
    productSettings: LedgerProductSettings,
    bookmarkStore: SecurityScopedBookmarkStore,
    widgetProjectionPublisher: RedactedWidgetProjectionPublisher? = nil,
    intentConsumer: @escaping () -> LedgerIntentRequest? = { nil },
    scopeStarter: @escaping (URL) -> Bool = { LedgerLocations.startAccess($0) },
    scopeStopper: @escaping (URL) -> Void = { LedgerLocations.stopAccess($0) }
  ) {
    _selection = State(initialValue: initialSelection)
    _session = State(
      initialValue: LedgerSession(testingScopeStarter: scopeStarter, testingScopeStopper: scopeStopper))
    _appLock = State(initialValue: appLock)
    _productSettings = State(initialValue: productSettings)
    self.importReviewSummary = importReviewSummary ?? .awaitingSyntheticMetadata
    self.bookmarkStore = bookmarkStore
    self.widgetProjectionPublisher = widgetProjectionPublisher
    self.intentConsumer = intentConsumer
    self.scopeStarter = scopeStarter
    self.scopeStopper = scopeStopper
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
      if appLock.isLocked {
        LockedSurface(
          lock: appLock,
          unlock: { appLock.unlock(with: $0) },
          biometricUnlock: { await appLock.unlockWithBiometrics() })
      } else {
        destinationPreview
          .animation(
            MotionPolicy.navigationAnimation(reduceMotion: effectiveReduceMotion),
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
          .disabled(appLock.isLocked)
        Button("Open Ledger…", action: openLedger)
          .accessibilityLabel(Self.openLedgerActionLabel)
          .accessibilityHint("Opens a file panel for an existing Ledger Atlas ledger.")
          .keyboardShortcut("o", modifiers: .command)
          .disabled(appLock.isLocked)
      }
    }
    .fileImporter(
      isPresented: $isChoosingImportSource, allowedContentTypes: Self.importTypes,
      allowsMultipleSelection: false
    ) { result in
      guard !appLock.isLocked, case .success(let urls) = result, let url = urls.first else { return }
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
      // The staging copy is scratch; the approved ledger goes to app storage so it survives.
      guard let ledgers = try? LedgerLocations.ledgersDirectory() else {
        journey.recordFailure("Ledger Atlas could not prepare its ledger storage.")
        return
      }
      let canonical = LedgerLocations.availableURL(named: "Money Manager import", in: ledgers)
      Task {
        await journey.selectSourceInBackground(
          url, stagingDatabaseURL: directory.appendingPathComponent("stage.sqlite"),
          canonicalDatabaseURL: canonical, sourceTimeZone: sourceTimeZone)
      }
    }
    .task {
      if LedgerDemoTour.isRequested {
        await runDemoTour()
        return
      }
      portal.lockDidChange(isLocked: appLock.isLocked)
      if appLock.isLocked { closeLockedLedger() } else { startSavedLedgerReopen() }
    }
    .onReceive(NotificationCenter.default.publisher(for: LedgerIntentBridge.didEnqueueNotification)) { _ in
      consumePendingIntentIfUnlocked()
    }
    .onChange(of: journey.ledgerURL) { _, ledger in
      portal.ledgerDidChange(to: ledger)
    }
    .onChange(of: appLock.isLocked) { _, locked in
      portal.lockDidChange(isLocked: locked)
      if locked {
        closeLockedLedger()
      } else {
        startSavedLedgerReopen()
        consumePendingIntentIfUnlocked()
      }
    }
    .onChange(of: journey.snapshotGeneration) { _, _ in
      // Keep the widget's counts current after every edit. A failed refresh is reported but
      // doesn't close the ledger.
      guard !appLock.isLocked, journey.snapshot != nil else { return }
      Self.publishWidget(
        .ready, publisher: widgetProjectionPublisher, journey: journey, session: session,
        closeLedgerOnFailure: false)
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

  private static var packageTypes: [UTType] {
    if let package = UTType(filenameExtension: "ledgerpackage") { return [package, .data] }
    return [.data]
  }

  /// New ledgers live in app storage (see `LedgerLocations`), so creating one only asks for a
  /// name.
  private func createLedger() {
    guard !appLock.isLocked else { return }
    let alert = NSAlert()
    alert.messageText = Self.createLedgerActionLabel
    alert.informativeText = Self.createLedgerPanelMessage
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.stringValue = "My Ledger"
    alert.accessoryView = field
    alert.addButton(withTitle: "Create")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    guard let directory = try? LedgerLocations.ledgersDirectory() else {
      journey.recordFailure("Ledger Atlas could not prepare its ledger storage.")
      return
    }
    performLedgerSelection(
      .create, url: LedgerLocations.availableURL(named: field.stringValue, in: directory))
  }

  /// A ledger already in app storage opens in place. One from anywhere else is copied in first,
  /// because the sandbox will not let SQLite write its journal next to a picked file.
  private func openLedger() {
    guard !appLock.isLocked else { return }
    let directory = try? LedgerLocations.ledgersDirectory()
    let panel = NSOpenPanel()
    panel.title = Self.openLedgerActionLabel
    panel.prompt = "Open"
    panel.message = Self.openLedgerPanelMessage
    panel.allowedContentTypes = Self.ledgerTypes
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.directoryURL = directory
    guard panel.runModal() == .OK, let picked = panel.url, let directory else { return }
    if LedgerLocations.isInside(picked, directory) {
      performLedgerSelection(.open, url: picked)
      return
    }
    guard picked.startAccessingSecurityScopedResource() else {
      journey.recordFailure("Ledger access was not granted. Choose Open Ledger to retry.")
      return
    }
    defer { picked.stopAccessingSecurityScopedResource() }
    do {
      performLedgerSelection(.open, url: try LedgerLocations.importCopy(of: picked, into: directory))
    } catch {
      journey.recordFailure("The ledger could not be copied into Ledger Atlas. The original is unchanged.")
    }
  }

  private func performLedgerSelection(_ operation: LedgerLifecycleOperation, url: URL?) {
    guard !appLock.isLocked, url != nil else { return }
    lifecycleTask?.cancel()
    lifecycleGeneration &+= 1
    let generation = lifecycleGeneration
    lifecycleTask = Task {
      let outcome = await Self.performLedgerSelection(
        operation, url: url, bookmarkStore: bookmarkStore,
        widgetPublisher: widgetProjectionPublisher, journey: journey, session: session,
        scopeStarter: scopeStarter, scopeStopper: scopeStopper,
        isCurrent: { !appLock.isLocked && lifecycleGeneration == generation })
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
    guard !appLock.isLocked else { return }
    lifecycleTask?.cancel()
    lifecycleGeneration &+= 1
    let generation = lifecycleGeneration
    lifecycleTask = Task {
      let outcome = await Self.reopenSavedLedger(
        bookmarkStore: bookmarkStore, widgetPublisher: widgetProjectionPublisher,
        journey: journey, session: session,
        scopeStarter: scopeStarter, scopeStopper: scopeStopper,
        isCurrent: { !appLock.isLocked && lifecycleGeneration == generation })
      guard lifecycleGeneration == generation else {
        recordSupersededPublication(outcome)
        return
      }
      lifecycleMessage = outcome.message
      lifecycleRetryOperation = outcome.retryOperation
      // Reopening at launch or after unlock lands on the start screen chosen in Settings.
      if [.opened, .upgraded].contains(outcome.kind) { selection = productSettings.startScreen }
      // A Shortcuts request that launched the app was queued before this view listened, so it
      // is taken here, once the ledger is back. Its screen wins over the start screen.
      if let pendingIntent { route(pendingIntent) }
      consumePendingIntentIfUnlocked()
    }
  }

  /// See `LedgerDemoTour`. Creates the synthetic demo ledger, opens it like Open Ledger does,
  /// saves one PNG per screen, writes `tour.txt` and quits. Prints where the files are.
  private func runDemoTour() async {
    func log(_ line: String) {
      FileHandle.standardOutput.write(Data("[demo-tour] \(line)\n".utf8))
    }
    do {
      let output = try LedgerDemoTour.outputDirectory()
      log("output \(output.path)")
      guard !appLock.isLocked else {
        log("refused: App Lock is on")
        NSApplication.shared.terminate(nil)
        return
      }
      guard let url = try LedgerDemoTour.demoLedgerURL(in: LedgerLocations.ledgersDirectory())
      else {
        log("refused: this Mac already has ledgers; the tour only runs on a fresh install")
        NSApplication.shared.terminate(nil)
        return
      }
      defer {
        session.close()
        journey.closeLedger()
        bookmarkStore.clear()
        LedgerDemoTour.removeDemoLedger(at: url)
      }
      try LedgerDemoTour.makeDemoLedger(at: url)
      log("demo ledger created")
      performLedgerSelection(.open, url: url)
      for _ in 0..<100 where journey.snapshot == nil {
        try await Task.sleep(for: .milliseconds(200))
      }
      log(journey.snapshot == nil ? "ledger did not open: \(journey.lastFailure ?? lifecycleMessage ?? "-")" : "ledger opened")
      var lines: [String] = []
      for (index, destination) in LedgerDemoTour.destinations.enumerated() {
        selection = destination
        try await Task.sleep(for: .milliseconds(1_500))
        let name = String(format: "%02d-%@.png", index + 1, destination.rawValue)
        let saved = LedgerDemoTour.capture(to: output.appendingPathComponent(name))
        lines.append("\(name)\t\(destination.title)\t\(saved ? "ok" : "failed")")
        log("\(destination.title): \(saved ? "saved" : "capture failed")")
      }
      try lines.joined(separator: "\n").write(
        to: output.appendingPathComponent("tour.txt"), atomically: true, encoding: .utf8)
      log("done")
    } catch {
      log("failed: \(error)")
    }
    NSApplication.shared.terminate(nil)
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
    guard let statement = try? LedgerStatement(snapshot: snapshot) else {
      journey.recordFailure("The report could not be generated.")
      return
    }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType.pdf]
    panel.nameFieldStringValue = "ledger-atlas-statement.pdf"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try LedgerPDFStatementExporter.export(statement, to: url)
    } catch {
      journey.recordFailure("The PDF statement could not be saved.")
    }
  }

  private func exportPeriodStatement(_ report: InsightsReport, title: String, hidingNames: Bool) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType.pdf]
    panel.nameFieldStringValue = "ledger-atlas-statement-\(LedgerPeriodStatistics.isoText(report.period.start)).pdf"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try LedgerPDFStatementExporter.export(
        lines: report.statementLines(redactingNames: hidingNames, title: title), to: url)
    } catch {
      journey.recordFailure("The PDF statement could not be saved.")
    }
  }

  private static let xlsxType = UTType(filenameExtension: "xlsx") ?? .data

  private func exportXLSXWorkbook() {
    guard journey.snapshot != nil else {
      journey.recordFailure("Open a ledger before exporting a workbook.")
      return
    }
    guard Self.confirmPlaintextExport() else { return }
    let panel = NSSavePanel()
    panel.title = "Export XLSX workbook"
    panel.prompt = "Export"
    panel.allowedContentTypes = [Self.xlsxType]
    panel.nameFieldStringValue = "ledger-atlas.xlsx"
    panel.message = "Receipt images aren't included in the workbook. Save 1:1 backup keeps them."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try journey.exportXLSX(to: url)
      lifecycleMessage = "Workbook exported."
    } catch {
      journey.recordFailure("The workbook could not be saved.")
    }
  }

  private func importXLSXWorkbook() {
    guard journey.snapshot != nil else {
      journey.recordFailure("Open a ledger before importing a workbook.")
      return
    }
    let openPanel = NSOpenPanel()
    openPanel.title = "Choose an XLSX workbook"
    openPanel.allowedContentTypes = [Self.xlsxType]
    openPanel.allowsMultipleSelection = false
    openPanel.canChooseDirectories = false
    guard openPanel.runModal() == .OK, let source = openPanel.url else { return }
    let scoped = source.startAccessingSecurityScopedResource()
    defer { if scoped { source.stopAccessingSecurityScopedResource() } }

    let plan: LedgerXLSXImportPlan
    do {
      plan = try journey.planXLSXImport(from: source)
    } catch LedgerXLSXExchange.Error.invalid(let issues) {
      let alert = NSAlert()
      alert.messageText = "This workbook can't be imported"
      alert.informativeText =
        (issues.prefix(8).map { "• \($0.description)" }
        + (issues.count > 8 ? ["…and \(issues.count - 8) more."] : []))
        .joined(separator: "\n")
      alert.runModal()
      return
    } catch {
      journey.recordFailure("The workbook could not be read. Choose an XLSX file exported from a spreadsheet app.")
      return
    }

    let alert = NSAlert()
    alert.informativeText = LedgerJourney.xlsxImportPreview(plan)
    guard plan.canApply, !plan.isEmpty else {
      alert.messageText = plan.canApply ? "Nothing to import" : "This workbook can't be imported"
      alert.runModal()
      return
    }
    alert.messageText = "Import this workbook into the open ledger?"
    alert.addButton(withTitle: "Import")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    // Editing starts only once the person has confirmed, so cancelling leaves the ledger as it
    // was. The plan is checked again inside the write, so reopening for editing is safe.
    if !journey.isEditing {
      do {
        try journey.performBeginEditing()
      } catch {
        journey.recordFailure("This ledger can't be edited, so the workbook wasn't imported.")
        return
      }
    }
    do {
      try journey.applyXLSXImport(
        plan, createdAt: UTCInstant(epochMilliseconds: UTCInstant.currentEpochMilliseconds()))
      lifecycleMessage = "Workbook imported. Nothing that was already in the ledger changed."
    } catch {
      journey.recordFailure(
        "The workbook was not imported and the ledger is unchanged. If the ledger changed while you were choosing, try again.")
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
    let contents =
      "The backup contains \(preview.accounts.count) accounts, \(preview.transactions.count) transactions, and \(preview.categories.count) categories. The original backup stays unchanged."
    switch chooseRestoreMode(title: "Restore this backup?", contents: contents) {
    case .cancel: return
    case .merge:
      mergeBackup(from: source)
      return
    case .replace: break
    }
    guard let directory = try? LedgerLocations.ledgersDirectory() else {
      journey.recordFailure("Ledger Atlas could not prepare its ledger storage.")
      return
    }
    let destination = LedgerLocations.availableURL(
      named: source.deletingPathExtension().lastPathComponent + " restored", in: directory)
    do {
      try journey.restoreCanonicalBackup(from: source, to: destination)
      performLedgerSelection(.open, url: destination)
      lifecycleMessage = "Backup restored as a new ledger."
    } catch {
      journey.recordFailure("The backup could not be restored without replacing existing data.")
    }
  }

  private func exportPortablePackage() {
    guard Self.confirmPlaintextExport() else { return }
    let panel = NSSavePanel()
    panel.title = "Export portable package"
    panel.prompt = "Export"
    panel.allowedContentTypes = Self.packageTypes
    panel.nameFieldStringValue = "ledger-atlas.ledgerpackage"
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    do {
      let includesImportHistory = try journey.exportPortablePackage(to: destination)
      lifecycleMessage = LedgerJourney.packageExportSuccessMessage(
        includesImportHistory: includesImportHistory)
    } catch {
      journey.recordFailure(LedgerJourney.packageExportFailureMessage(for: error))
    }
  }

  private func restorePortablePackage() {
    let openPanel = NSOpenPanel()
    openPanel.title = "Choose a portable package"
    openPanel.allowedContentTypes = Self.packageTypes
    openPanel.allowsMultipleSelection = false
    openPanel.canChooseDirectories = false
    guard openPanel.runModal() == .OK, let source = openPanel.url else { return }
    guard source.startAccessingSecurityScopedResource() else {
      journey.recordFailure("Package access was not granted.")
      return
    }
    defer { source.stopAccessingSecurityScopedResource() }
    guard
      let data = try? Data(contentsOf: source, options: .mappedIfSafe),
      (try? LedgerPortablePackageFile.decode(data)) != nil
    else {
      journey.recordFailure("The selected portable package is invalid or incomplete.")
      return
    }
    switch chooseRestoreMode(
      title: "Import this portable package?",
      contents:
        "The package is limited to representable Ledger Atlas data. The source stays unchanged.")
    {
    case .cancel: return
    case .merge:
      mergeBackup(from: source)
      return
    case .replace: break
    }
    guard let directory = try? LedgerLocations.ledgersDirectory() else {
      journey.recordFailure("Ledger Atlas could not prepare its ledger storage.")
      return
    }
    let destination = LedgerLocations.availableURL(
      named: source.deletingPathExtension().lastPathComponent, in: directory)
    do {
      try journey.restorePortablePackage(from: source, to: destination)
      performLedgerSelection(.open, url: destination)
      lifecycleMessage = "Portable package imported as a new ledger."
    } catch {
      journey.recordFailure(LedgerJourney.packageRestoreFailureMessage(for: error))
    }
  }

  private enum RestoreMode { case replace, merge, cancel }

  /// Asks how to use a backup. With a ledger open, the person picks replace or merge; both
  /// build a new ledger file and keep the current one, so either can be undone by reopening it.
  private func chooseRestoreMode(title: String, contents: String) -> RestoreMode {
    let alert = NSAlert()
    alert.messageText = title
    guard journey.snapshot != nil else {
      alert.informativeText = contents
      alert.addButton(withTitle: "Restore")
      alert.addButton(withTitle: "Cancel")
      return alert.runModal() == .alertFirstButtonReturn ? .replace : .cancel
    }
    alert.informativeText = contents + " " + Self.restoreModesExplanation
    alert.addButton(withTitle: "Replace open ledger")
    alert.addButton(withTitle: "Merge into open ledger…")
    alert.addButton(withTitle: "Cancel")
    switch alert.runModal() {
    case .alertFirstButtonReturn: return .replace
    case .alertSecondButtonReturn: return .merge
    default: return .cancel
    }
  }

  package static let restoreModesExplanation =
    "Replace switches to the backup. Merge adds what the backup has and the open ledger lacks. Either way your current ledger file is kept, so you can reopen it from Open Ledger."

  /// Previews a merge from counts only, then builds the merged ledger as a new file.
  private func mergeBackup(from source: URL) {
    let incoming: (manifest: LedgerExportManifest, payload: Data)
    let summary: LedgerMergeSummary
    do {
      incoming = try LedgerJourney.incomingPackage(from: source)
      summary = try journey.previewMerge(incoming)
    } catch {
      journey.recordFailure(LedgerJourney.mergeFailureMessage(for: error))
      return
    }
    guard !summary.isEmpty else {
      lifecycleMessage = LedgerJourney.mergePreviewMessage(summary)
      return
    }
    let alert = NSAlert()
    alert.messageText = "Merge this backup into the open ledger?"
    alert.informativeText = LedgerJourney.mergePreviewMessage(summary)
    alert.addButton(withTitle: "Merge")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    guard let directory = try? LedgerLocations.ledgersDirectory() else {
      journey.recordFailure("Ledger Atlas could not prepare its ledger storage.")
      return
    }
    let destination = LedgerLocations.availableURL(
      named: Self.currentLedgerName(journey) + " merged", in: directory)
    do {
      try journey.mergeIntoNewLedger(incoming, at: destination)
      performLedgerSelection(.open, url: destination)
      lifecycleMessage = "Backup merged. The ledger from before the merge is kept in Open Ledger."
    } catch {
      journey.recordFailure(LedgerJourney.mergeFailureMessage(for: error))
    }
  }

  /// Contents-only or complete reset. Builds a replacement ledger and switches to it only
  /// once it is complete, so an interrupted reset leaves the current ledger in use.
  private func resetLedger() {
    guard journey.snapshot != nil else {
      journey.recordFailure("Open a ledger before resetting it.")
      return
    }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Reset this ledger?"
    alert.informativeText = Self.resetExplanation
    alert.addButton(withTitle: "Erase transactions only")
    alert.addButton(withTitle: "Erase everything")
    alert.addButton(withTitle: "Cancel")
    let scope: LedgerResetScope
    switch alert.runModal() {
    case .alertFirstButtonReturn: scope = .contentsOnly
    case .alertSecondButtonReturn: scope = .complete
    default: return
    }
    guard let directory = try? LedgerLocations.ledgersDirectory() else {
      journey.recordFailure("Ledger Atlas could not prepare its ledger storage.")
      return
    }
    let destination = LedgerLocations.availableURL(
      named: Self.currentLedgerName(journey) + " reset", in: directory)
    do {
      try journey.resetLedger(scope, at: destination)
      performLedgerSelection(.open, url: destination)
      lifecycleMessage = "Ledger reset. The ledger from before the reset is kept in Open Ledger."
    } catch {
      journey.recordFailure("The ledger could not be reset. Nothing was changed.")
    }
  }

  package static let resetExplanation =
    "Erase transactions only keeps your accounts, categories, tags and templates, and removes transactions, budgets, recurring rules, installment plans, memos and receipts. Erase everything starts an empty ledger. Your current ledger file is kept, so you can reopen it from Open Ledger."

  package static func currentLedgerName(_ journey: LedgerJourney) -> String {
    journey.ledgerURL?.deletingPathExtension().lastPathComponent ?? "Ledger"
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
      try publisher.publish(projection: widgetProjection(for: state, journey: journey))
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

  /// A ready state carries the open ledger's redacted summary; every other state is bare.
  static func widgetProjection(
    for state: RedactedWidgetProjection.State, journey: LedgerJourney, now: Date = Date()
  ) -> RedactedWidgetProjection {
    guard state == .ready, let snapshot = journey.snapshot else { return .init(state: state) }
    return .ready(
      snapshot: snapshot, today: LedgerPeriodRule.today(in: .current, now: now))
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

  /// Asks before a plaintext copy of the ledger is written (LA-004).
  private static func confirmPlaintextExport() -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = LedgerJourney.plaintextExportWarning.title
    alert.informativeText = LedgerJourney.plaintextExportWarning.message
    alert.addButton(withTitle: "Continue")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  package static func backupSavedMessage(sha256: String) -> String {
    "Backup saved. SHA-256: \(sha256)"
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
    case .resolved(let url), .stale(let url):
      // A stale bookmark is renewed by the successful open below, which saves it again.
      return await performLedgerLifecycle(
        .open, at: url, bookmarkStore: bookmarkStore, widgetPublisher: widgetPublisher,
        journey: journey, session: session, scopeStarter: scopeStarter,
        scopeStopper: scopeStopper, lifecycle: lifecycle, isCurrent: isCurrent)
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

  /// Commits the reviewed import in the background, then keeps the new ledger's access and
  /// shows it.
  private func approveImport() async {
    guard await journey.approveInBackground(into: session) else { return }
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

  @ViewBuilder
  private var destinationPreview: some View {
    if selection != .importReview, selection != .onboarding, session.screen == .loading {
      OpeningLedgerView()
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
        .disabled(journey.isSourceTimeZoneSelectionLocked || journey.backgroundWork != nil)
        Button("Choose Money Manager backup…") { isChoosingImportSource = true }
          .accessibilityLabel("Choose Money Manager backup")
          .disabled(sourceTimeZoneIdentifier.isEmpty || journey.backgroundWork != nil)
        if let work = journey.backgroundWork {
          ImportProgressView(work: work)
        }
        if journey.phase == .reviewing {
          Button("Approve import") {
            Task { await approveImport() }
          }
          .accessibilityLabel("Approve import")
          .disabled(journey.backgroundWork != nil)
        }
      }
      .id(selection)
    } else if selection == .ledger {
      let listing = splitListing
      LedgerView(
        state: session.state, isEditing: journey.isEditing,
        accounts: journey.snapshot?.accounts ?? [], categories: journey.snapshot?.categories ?? [],
        transactions: journey.snapshot?.transactions ?? [],
        splitPurchases: listing?.purchases ?? [],
        splitTransactionIDs: splitTransactionIDs(listing),
        splitNotice: listing?.unreadableNotice,
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
          } catch {
            journey.recordFailure(
              LedgerJourney.editFailureMessage(
                for: error, otherwise: "Transaction could not be closed."))
          }
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
        createTransaction: { submissionID, amount, kind, accountID, categoryID, note, tags in
          do {
            _ = try journey.createNativeTransaction(
              amountLiteral: amount, kind: kind, accountID: accountID,
              categoryID: categoryID, note: note,
              createdAt: UTCInstant(epochMilliseconds: UTCInstant.currentEpochMilliseconds()),
              submissionID: submissionID, tags: tags)
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
        },
        tags: journey.snapshot?.tags ?? [],
        revisionTags: journey.snapshot?.revisionTags ?? [:],
        saveTags: { transactionID, tags in
          do {
            try journey.setTags(
              tags, onTransaction: transactionID,
              createdAt: UTCInstant(epochMilliseconds: UTCInstant.currentEpochMilliseconds()))
          } catch {
            journey.recordFailure(
              LedgerJourney.editFailureMessage(for: error, otherwise: "Tags could not be saved."))
          }
        },
        saveAsTemplate: { transactionID, name in
          do { try journey.saveTemplate(fromTransaction: transactionID, name: name) }
          catch {
            journey.recordFailure("This transaction can't be saved as a template.")
          }
        },
        editSplit: { draft in
          do {
            _ = try journey.editSplit(
              draft, createdAt: UTCInstant(epochMilliseconds: UTCInstant.currentEpochMilliseconds()))
          } catch {
            journey.recordFailure(
              LedgerJourney.editFailureMessage(
                for: error,
                otherwise: "Split purchase could not be saved. Lines must add up to the total."))
          }
        },
        closeSplit: { purchaseID in
          do {
            try journey.closeSplit(
              purchaseID: purchaseID,
              createdAt: UTCInstant(epochMilliseconds: UTCInstant.currentEpochMilliseconds()))
          } catch {
            journey.recordFailure(
              LedgerJourney.editFailureMessage(
                for: error, otherwise: "Split purchase could not be closed."))
          }
        }
      )
      .id(selection)
    } else if selection == .receipts {
      ReceiptSurface(journey: journey)
        .id(selection)
    } else if selection == .localAccess {
      LocalAccessSurface(
        accountCount: journey.snapshot?.accounts.count ?? 0,
        transactionCount: journey.snapshot?.transactions.count ?? 0,
        ledgerURL: journey.ledgerURL, portal: portal)
        .id(selection)
    } else if selection == .backupRestore {
      BackupSurface(
        rows: journey.rows(for: .backupRestore),
        emptyMessage: selection.emptyStateMessage,
        lastFailure: journey.lastFailure,
        status: lifecycleMessage,
        open: openLedger,
        saveBackup: {
          guard Self.confirmPlaintextExport() else { return }
          let panel = NSSavePanel()
          panel.allowedContentTypes = [.database, .data]
          panel.nameFieldStringValue = "ledger-atlas-backup.sqlite"
          guard panel.runModal() == .OK, let url = panel.url else { return }
          do {
            let digest = try journey.backupCanonicalLedger(to: url)
            lifecycleMessage = Self.backupSavedMessage(sha256: digest)
          } catch {
            lifecycleMessage = nil
            journey.recordFailure(Self.backupFailureMessage(for: error))
          }
        },
        restoreBackup: restoreBackup,
        exportPackage: exportPortablePackage,
        restorePackage: restorePortablePackage,
        reset: journey.snapshot.map { _ in resetLedger },
        exportXLSX: journey.snapshot.map { _ in exportXLSXWorkbook },
        importXLSX: journey.snapshot.map { _ in importXLSXWorkbook }
      )
      .id(selection)
    } else if selection == .transfers {
      TransferSurface(
        rows: journey.rows(for: .transfers),
        accounts: journey.snapshot?.accounts ?? [], intentRequest: pendingIntent,
        consumeIntent: { pendingIntent = nil }, isEditing: journey.isEditing,
        lastFailure: lifecycleMessage ?? journey.lastFailure,
        beginEditing: { try? journey.performBeginEditing() },
        createTransfer: {
          submissionID, sourceID, destinationID, sourceAmount, destinationAmount, feeAmount,
          feeAccountID in
          do {
            _ = try journey.createNativeTransfer(
              sourceAccountID: sourceID, destinationAccountID: destinationID,
              sourceAmountLiteral: sourceAmount, destinationAmountLiteral: destinationAmount,
              rateLiteral: nil, feeAmountLiteral: feeAmount, feeAccountID: feeAccountID,
              createdAt: UTCInstant(epochMilliseconds: UTCInstant.currentEpochMilliseconds()),
              submissionID: submissionID)
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
        transactions: journey.snapshot?.transactions ?? [],
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
        categories: journey.snapshot?.categories ?? [],
        transactions: journey.snapshot?.transactions ?? [], isEditing: journey.isEditing,
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
    } else if selection == .tags {
      TagsView(
        state: session.state, tags: journey.snapshot?.tags ?? [],
        templates: journey.snapshot?.transactionTemplates ?? [],
        memos: journey.snapshot?.memos ?? [],
        transactions: journey.snapshot?.transactions ?? [],
        revisionTags: journey.snapshot?.revisionTags ?? [:],
        accounts: journey.snapshot?.accounts ?? [], categories: journey.snapshot?.categories ?? [],
        isEditing: journey.isEditing, lastFailure: lifecycleMessage ?? journey.lastFailure,
        beginEditing: { try? journey.performBeginEditing() },
        createTag: { tag in
          do { try journey.createTag(tag) } catch {
            journey.recordFailure(
              LedgerJourney.annotationFailureMessage(for: error, otherwise: "Tag could not be created."))
          }
        },
        updateTag: { tag in
          do { try journey.updateTag(tag) } catch {
            journey.recordFailure(
              LedgerJourney.annotationFailureMessage(for: error, otherwise: "Tag could not be saved."))
          }
        },
        saveTemplate: { template in
          do { try journey.saveTransactionTemplate(template) }
          catch { journey.recordFailure("Template could not be saved.") }
        },
        useTemplate: { templateID, submissionID in
          do {
            _ = try journey.createTransaction(
              fromTemplate: templateID,
              createdAt: UTCInstant(epochMilliseconds: UTCInstant.currentEpochMilliseconds()),
              submissionID: submissionID)
          } catch { journey.recordFailure("Transaction could not be recorded from the template.") }
        },
        saveMemo: { memo in
          do { try journey.saveMemo(memo) }
          catch { journey.recordFailure("Memo could not be saved.") }
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
        transactions: journey.snapshot?.transactions ?? [],
        today: try? LedgerJourney.localDate(
          for: UTCInstant(epochMilliseconds: UTCInstant.currentEpochMilliseconds()),
          in: .current),
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
        emptyMessage: selection.emptyStateMessage,
        snapshot: journey.snapshot,
        settings: productSettings
      ) { openLedger() } exportPDF: {
        exportPDFStatement()
      } exportPeriodPDF: { report, title, hideNames in
        exportPeriodStatement(report, title: title, hidingNames: hideNames)
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

  private var splitListing: LedgerSplitPurchaseListing? {
    journey.snapshot.map(LedgerApplication.splitPurchaseListing(from:))
  }

  /// Members of split groups that were read; members of unreadable groups stay in the main list.
  private func splitTransactionIDs(_ listing: LedgerSplitPurchaseListing?) -> Set<String> {
    guard let snapshot = journey.snapshot else { return [] }
    return Set(
      snapshot.transactions.filter { transaction in
        transaction.links.contains { $0.kind == .split }
      }.map(\.id)
    ).subtracting(listing?.unreadableTransactionIDs ?? [])
      .subtracting(listing?.closedTransactionIDs ?? [])
  }

  private func lockApp() {
    guard appLock.hasPasscode else { return }
    appLock.lock()
    closeLockedLedger()
  }

  private func closeLockedLedger() {
    lifecycleTask?.cancel()
    lifecycleGeneration &+= 1
    session.close()
    journey.closeLedger()
    _ = publishWidget(.locked)
  }

  private func consumePendingIntentIfUnlocked() {
    // A request the ledger never showed (no ledger open, for example) expires instead of
    // blocking the next one.
    if let pendingIntent,
      pendingIntent.isExpired(atMilliseconds: LedgerIntentBridge.nowMilliseconds())
    {
      self.pendingIntent = nil
    }
    guard !appLock.isLocked, pendingIntent == nil,
      let request = intentConsumer()
    else { return }
    route(request)
  }

  private func route(_ request: LedgerIntentRequest) {
    switch request.kind {
    case .addExpense, .addIncome:
      pendingIntent = request
      selection = .ledger
    case .addTransfer:
      pendingIntent = request
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
