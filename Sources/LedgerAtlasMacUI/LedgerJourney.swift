import CryptoKit
import Foundation
import LedgerCore
import LedgerStore
internal import MMImport
import Observation

@MainActor
@Observable
public final class LedgerJourney {
  public enum Phase: Equatable, Sendable {
    case idle
    case reviewing
    case blocked
    case imported
    case failed
  }

  public struct SurfaceRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
  }

  public private(set) var phase: Phase = .idle
  private var review: ImportWorkspace.Review?
  public private(set) var summary: ImportReviewSummary = .awaitingSyntheticMetadata
  public private(set) var snapshot: LedgerStore.LedgerReadSnapshot? {
    didSet { snapshotGeneration &+= 1 }
  }
  /// Changes whenever `snapshot` is replaced, so views can react without comparing snapshots.
  public private(set) var snapshotGeneration = 0
  public private(set) var ledgerURL: URL?
  public private(set) var searchQuery = LedgerSearchQuery()
  public private(set) var lastFailure: String?
  public var reduceMotion: Bool = false
  public var isEditing: Bool { application != nil }
  public var isSourceTimeZoneSelectionLocked: Bool { phase == .reviewing || phase == .imported }
  private var canonicalURL: URL?

  private var prepared: ImportWorkspace.PreparedHandle?
  private let workspace = ImportWorkspace()
  private var application: LedgerApplication?
  private var mutableStore: LedgerStore?
  private var openedStore: LedgerStore?

  public init() {}

  public func selectSource(
    _ sourceURL: URL, stagingDatabaseURL: URL, canonicalDatabaseURL: URL,
    sourceTimeZone: SourceTimeZone
  ) throws {
    disconnectLedger()
    lastFailure = nil
    let preparation = try workspace.prepare(
      .init(
        sourceURL: sourceURL, stagingDatabaseURL: stagingDatabaseURL,
        canonicalDatabaseURL: canonicalDatabaseURL, sourceTimeZone: sourceTimeZone))
    review = preparation.review
    let data = try JSONEncoder().encode(preparation.review)
    summary = ImportReviewSummary(
      workspaceReviewJSON: data, sourceTimeZoneIdentifier: sourceTimeZone.ianaIdentifier)
    prepared = preparation.preparedHandle
    canonicalURL = requestCanonicalURL(canonicalDatabaseURL)
    ledgerURL = nil
    application = nil
    mutableStore = nil
    openedStore = nil
    phase = preparation.preparedHandle == nil ? .blocked : .reviewing
  }

  public func performSelectSource(
    _ sourceURL: URL, stagingDatabaseURL: URL, canonicalDatabaseURL: URL,
    sourceTimeZone: SourceTimeZone
  ) {
    do {
      try selectSource(
        sourceURL, stagingDatabaseURL: stagingDatabaseURL,
        canonicalDatabaseURL: canonicalDatabaseURL, sourceTimeZone: sourceTimeZone)
    } catch {
      failClosed(message: "Import could not be prepared.")
    }
  }

  private func requestCanonicalURL(_ url: URL) -> URL { url }

  public func approvePreparedImport() throws {
    guard let canonicalURL else {
      failClosed(message: "Import could not be approved.")
      throw LedgerApplication.Error.invalidCommand
    }
    try approveAndOpen(canonicalDatabaseURL: canonicalURL)
  }

  public func approveAndOpen(canonicalDatabaseURL: URL) throws {
    guard let prepared else {
      failClosed(message: "Import could not be approved.")
      throw LedgerApplication.Error.invalidCommand
    }
    let approval = workspace.approve(prepared)
    _ = try workspace.commit(prepared, approval: approval)
    application = nil
    mutableStore = nil
    let store = try LedgerStore.openReadOnly(at: canonicalDatabaseURL)
    snapshot = try store.readSnapshot()
    openedStore = store
    ledgerURL = canonicalDatabaseURL
    canonicalURL = canonicalDatabaseURL
    phase = .imported
  }

  public func openLedger(_ url: URL) {
    disconnectLedger()
    lastFailure = nil
    do {
      let store = try LedgerStore.openReadOnly(at: url)
      snapshot = try store.readSnapshot()
      openedStore = store
      ledgerURL = url
      canonicalURL = url
      phase = snapshot == nil ? .failed : .imported
    } catch {
      disconnectLedger()
      lastFailure = "Ledger could not be opened."
      phase = .failed
    }
  }

  package func openValidatedLedger(_ store: LedgerStore, at url: URL) throws
    -> LedgerStore.LedgerReadSnapshot
  {
    do {
      let snapshot = try store.readSnapshot()
      adoptValidatedLedger(store, snapshot: snapshot, at: url)
      return snapshot
    } catch {
      disconnectLedger()
      lastFailure = "Ledger could not be opened."
      phase = .failed
      throw error
    }
  }

  package func adoptValidatedLedger(
    _ store: LedgerStore, snapshot: LedgerStore.LedgerReadSnapshot, at url: URL
  ) {
    disconnectLedger()
    lastFailure = nil
    self.snapshot = snapshot
    openedStore = store
    ledgerURL = url
    canonicalURL = url
    phase = .imported
  }

  public func beginEditing(_ url: URL) throws {
    let store = try LedgerStore.openForMutation(at: url)
    mutableStore = store
    openedStore = nil
    application = LedgerApplication(store: store)
    snapshot = try store.readSnapshot()
    canonicalURL = url
    ledgerURL = url
    phase = .imported
  }

  package func performApprove(into session: LedgerSession) {
    do {
      lastFailure = nil
      try LedgerShell.approve(self, into: session)
    } catch {
      failClosed(message: "Import could not be approved.")
    }
  }

  public func performBeginEditing() throws {
    guard let url = ledgerURL ?? canonicalURL else {
      failClosed(message: "Editing could not begin.")
      throw LedgerApplication.Error.invalidCommand
    }
    do {
      lastFailure = nil
      try LedgerShell.beginEditing(self)
      if ledgerURL == nil { ledgerURL = url }
    } catch {
      failClosed(message: "Editing could not begin.")
      throw error
    }
  }

  public func performCorrectAmount(
    transactionID: String, amountLiteral: String, createdAt: UTCInstant
  ) {
    do {
      lastFailure = nil
      try correctAmount(
        transactionID: transactionID, amountLiteral: amountLiteral, createdAt: createdAt)
    } catch {
      failClosed(message: Self.editFailureMessage(for: error, otherwise: "Amount could not be saved."))
    }
  }

  /// A stale edit is not a failure of the ledger: say what happened and show the latest version.
  package static func editFailureMessage(for error: Error, otherwise message: String) -> String {
    if case LedgerStore.Error.revisionConflict = error {
      return "This transaction changed since you opened it. The latest version is shown; edit it again."
    }
    return message
  }

  public func checksum() throws -> String {
    guard let url = ledgerURL ?? canonicalURL else {
      throw LedgerApplication.Error.invalidCommand
    }
    return try Self.checksum(url)
  }

  public func recordFailure(_ message: String) {
    failClosed(message: message)
  }

  func closeLedger() {
    disconnectLedger()
  }

  private func failClosed(message: String) {
    lastFailure = message
    if phase == .idle || phase == .reviewing { phase = .failed }
  }

  private func disconnectLedger() {
    phase = .idle
    prepared = nil
    review = nil
    summary = .awaitingSyntheticMetadata
    application = nil
    mutableStore = nil
    openedStore = nil
    snapshot = nil
    ledgerURL = nil
    canonicalURL = nil
  }

  public func correctAmount(
    transactionID: String, amountLiteral: String, createdAt: UTCInstant
  ) throws {
    guard
      let current = snapshot?.transactions.first(where: { $0.id == transactionID })?
        .currentRevision
    else { throw LedgerApplication.Error.invalidCommand }
    // Only the amount changes. Note, rounding policy, category, kind, dates and user-level literals
    // (tags, split/recurrence/installment ids) carry over; import provenance literals stay on the
    // original revision only (see the filter below).
    // Multi-effect drafts are edited only when every leg shares one currency (same-unit transfer),
    // since the new amount would otherwise be ambiguous.
    let unit = current.draft.effects[0].amount.unitCode
    guard current.draft.effects.allSatisfy({ $0.amount.unitCode == unit }) else {
      throw LedgerApplication.Error.invalidCommand
    }
    let newAmount = try CurrencyAmount(unitCode: unit, amount: ExactDecimal(amountLiteral))
    let draft = try LedgerTransactionDraft(
      effects: try current.draft.effects.map {
        try LedgerTransactionEffect(
          accountID: $0.accountID, direction: $0.direction, amount: newAmount)
      }, categoryID: current.draft.categoryID, kind: current.draft.kind,
      occurredAt: current.draft.occurredAt, note: current.draft.note,
      roundingPolicy: current.draft.roundingPolicy,
      sourceLiterals: current.draft.sourceLiterals.filter {
        // Import receipt markers are owned by the import health proof and must not be duplicated
        // onto a correction; user-level literals (tags, split/recurrence/installment ids) carry over.
        // `conversion.` is defensive: conversion literals only occur on cross-currency transfers,
        // which the guard above already refuses.
        !$0.field.hasPrefix("import.") && !$0.field.hasPrefix("conversion.")
      },
      origin: current.draft.origin)
    try edit(
      ledgerURL: ledgerURL ?? canonicalURL ?? URL(fileURLWithPath: "/"),
      transactionID: transactionID, expectedRevisionID: current.id, draft: draft,
      createdAt: createdAt)
  }

  public func tombstoneTransaction(transactionID: String, createdAt: UTCInstant) throws {
    guard let application,
      let current = snapshot?.transactions.first(where: { $0.id == transactionID })?.currentRevision
    else { throw LedgerApplication.Error.invalidCommand }
    do {
      _ = try application.tombstoneTransaction(
        transactionID: transactionID, expectedCurrentRevisionID: current.id, createdAt: createdAt)
      snapshot = try application.snapshot()
    } catch {
      snapshot = try? application.snapshot()
      throw error
    }
  }

  public func copyTransaction(transactionID: String, createdAt: UTCInstant) throws
    -> LedgerTransactionRevision
  {
    guard let application,
      let current = snapshot?.transactions.first(where: { $0.id == transactionID })?.currentRevision
    else { throw LedgerApplication.Error.invalidCommand }
    let draft = try LedgerTransactionDraft(
      effects: current.draft.effects, categoryID: current.draft.categoryID,
      kind: current.draft.kind, occurredAt: current.draft.occurredAt,
      note: current.draft.note, roundingPolicy: current.draft.roundingPolicy,
      origin: try LedgerOrigin.macNative())
    let key = SHA256.hash(
      data: Data("mac-native-copy:\(transactionID):\(createdAt.epochMilliseconds)".utf8)
    ).map { String(format: "%02x", $0) }.joined()
    let revision = try application.createTransaction(
      idempotencyKey: key, draft: draft, createdAt: createdAt)
    snapshot = try application.snapshot()
    return revision
  }

  public func setSearch(_ query: LedgerSearchQuery) {
    searchQuery = query
  }

  public var insightTable: String {
    guard let snapshot else { return "" }
    return (try? LedgerStatement(snapshot: snapshot))?.text ?? ""
  }

  public func performCreateMacTransaction(amountLiteral: String, createdAt: UTCInstant) {
    do {
      lastFailure = nil
      _ = try createMacNativeTransaction(amountLiteral: amountLiteral, createdAt: createdAt)
    } catch {
      failClosed(message: "Mac transaction could not be saved.")
    }
  }

  public func createMacNativeTransaction(
    amountLiteral: String, createdAt: UTCInstant
  ) throws -> LedgerTransactionRevision {
    guard application != nil, let snapshot, let account = snapshot.accounts.first else {
      throw LedgerApplication.Error.invalidCommand
    }
    return try createNativeTransaction(
      amountLiteral: amountLiteral, kind: .expense, accountID: account.id,
      categoryID: nil, note: nil, createdAt: createdAt)
  }

  public func createNativeTransaction(
    amountLiteral: String, kind: LedgerTransactionKind, accountID: String,
    categoryID: String?, note: String?, createdAt: UTCInstant, submissionID: String? = nil,
    tags: LedgerTagLinks = .empty
  ) throws -> LedgerTransactionRevision {
    guard application != nil, let snapshot,
      let account = snapshot.accounts.first(where: { $0.id == accountID }),
      kind == .income || kind == .expense
    else { throw LedgerApplication.Error.invalidCommand }
    let origin = try LedgerOrigin.macNative()
    let amount = try CurrencyAmount(
      unitCode: account.currencyUnit, amount: ExactDecimal(amountLiteral))
    let when = try Self.nativeTemporal(for: createdAt)
    // A form submission keys on its own ID, so pressing Save twice records one transaction.
    let keyMaterial =
      submissionID.map { "mac-native-submission:\($0)" }
      ?? "mac-native:\(createdAt.epochMilliseconds):\(amountLiteral):\(kind.rawValue):\(accountID):\(categoryID ?? ""):\(note ?? "")"
    let key = SHA256.hash(data: Data(keyMaterial.utf8)).map { String(format: "%02x", $0) }
      .joined()
    let draft = try LedgerTransactionDraft(
      effects: [
        try LedgerTransactionEffect(
          accountID: account.id,
          direction: kind == .income ? .increase : .decrease, amount: amount)
      ], categoryID: categoryID, kind: kind, occurredAt: when, note: note, origin: origin)
    return try createTransaction(
      idempotencyKey: key, draft: draft, createdAt: createdAt, tags: tags)
  }

  public func createNativeTransfer(
    sourceAccountID: String, destinationAccountID: String,
    sourceAmountLiteral: String, destinationAmountLiteral: String?, rateLiteral: String?,
    rateScale: Int = 10, feeAmountLiteral: String?, feeAccountID: String?, createdAt: UTCInstant,
    submissionID: String? = nil
  ) throws -> (transfer: LedgerTransactionRevision, fee: LedgerTransactionRevision?) {
    guard application != nil, let snapshot,
      sourceAccountID != destinationAccountID,
      let source = snapshot.accounts.first(where: { $0.id == sourceAccountID }),
      let destination = snapshot.accounts.first(where: { $0.id == destinationAccountID }),
      source.lifecycle == .active, destination.lifecycle == .active
    else { throw LedgerApplication.Error.invalidCommand }
    let sourceAmount = try CurrencyAmount(
      unitCode: source.currencyUnit, amount: ExactDecimal(sourceAmountLiteral))
    let destinationAmount: CurrencyAmount
    let conversion: LedgerConversion?
    if source.currencyUnit == destination.currencyUnit {
      let literal = destinationAmountLiteral?.trimmingCharacters(in: .whitespacesAndNewlines)
      destinationAmount = try CurrencyAmount(
        unitCode: destination.currencyUnit,
        amount: ExactDecimal(literal?.isEmpty == false ? literal! : sourceAmountLiteral))
      guard destinationAmount == sourceAmount else { throw LedgerApplication.Error.invalidCommand }
      conversion = nil
    } else {
      guard let destinationLiteral = destinationAmountLiteral,
        !destinationLiteral.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw LedgerApplication.Error.invalidCommand }
      destinationAmount = try CurrencyAmount(
        unitCode: destination.currencyUnit, amount: ExactDecimal(destinationLiteral))
      // The two amounts are the truth (what left, what arrived); the rate is derived from them
      // unless a caller supplies one explicitly.
      let trimmedRate = rateLiteral?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let rate =
        trimmedRate.isEmpty
        ? try LedgerConversion.impliedRate(
          sourceAmount: sourceAmount, convertedAmount: destinationAmount, scale: rateScale)
        : try ExactDecimal(trimmedRate)
      conversion = try LedgerConversion(
        sourceAmount: sourceAmount, convertedAmount: destinationAmount,
        rate: rate, rateScale: rateScale, rounding: .halfEven)
    }
    let fee: CurrencyAmount?
    if let feeLiteral = feeAmountLiteral,
      !feeLiteral.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      guard let feeAccountID,
        let feeAccount = snapshot.accounts.first(where: { $0.id == feeAccountID }),
        feeAccount.lifecycle == .active
      else { throw LedgerApplication.Error.invalidCommand }
      fee = try CurrencyAmount(
        unitCode: feeAccount.currencyUnit, amount: ExactDecimal(feeLiteral))
    } else {
      guard feeAccountID == nil || feeAccountID?.isEmpty == true else {
        throw LedgerApplication.Error.invalidCommand
      }
      fee = nil
    }
    let keyMaterial =
      submissionID.map { "mac-native-transfer-submission:\($0)" }
      ?? "mac-native-transfer:\(createdAt.epochMilliseconds):\(sourceAccountID):\(destinationAccountID):\(sourceAmountLiteral):\(destinationAmountLiteral ?? ""):\(rateLiteral ?? ""):\(feeAmountLiteral ?? ""):\(feeAccountID ?? "")"
    let key = SHA256.hash(data: Data(keyMaterial.utf8)).map { String(format: "%02x", $0) }
      .joined()
    return try createTransfer(
      idempotencyKey: key, sourceAccountID: sourceAccountID,
      destinationAccountID: destinationAccountID, sourceAmount: sourceAmount,
      destinationAmount: destinationAmount, conversion: conversion, fee: fee,
      feeAccountID: fee == nil ? nil : feeAccountID,
      occurredAt: try Self.nativeTemporal(for: createdAt), origin: try LedgerOrigin.macNative(),
      createdAt: createdAt)
  }

  /// "1 USD = 83.25 INR" for the transfer form, from the two typed amounts; nil until both parse.
  nonisolated package static func conversionPreview(
    sourceLiteral: String, sourceUnit: String, destinationLiteral: String, destinationUnit: String
  ) -> String? {
    guard
      let source = try? ExactDecimal(sourceLiteral.trimmingCharacters(in: .whitespacesAndNewlines)),
      let destination = try? ExactDecimal(
        destinationLiteral.trimmingCharacters(in: .whitespacesAndNewlines)),
      source.isPositive, destination.isPositive,
      let perUnit = try? destination.divided(by: source, scale: 6, rounding: .halfEven)
    else { return nil }
    return "1 \(sourceUnit) = \(perUnit.rawLiteral) \(destinationUnit)"
  }

  package static func localDate(for instant: UTCInstant, in timeZone: TimeZone) throws
    -> SourceLocalDate
  {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let date = Date(timeIntervalSince1970: TimeInterval(instant.epochMilliseconds) / 1_000)
    let components = calendar.dateComponents(
      [.year, .month, .day], from: date)
    guard let year = components.year, let month = components.month, let day = components.day else {
      throw LedgerApplication.Error.invalidCommand
    }
    return try SourceLocalDate(year: year, month: month, day: day)
  }

  package static func nativeTemporal(for instant: UTCInstant) throws -> SourceTemporal {
    let foundationTimeZone = TimeZone.current
    let localDate = try localDate(for: instant, in: foundationTimeZone)
    let nativeTimeZone = try SourceTimeZone(ianaIdentifier: foundationTimeZone.identifier)
    return try SourceTemporal(
      resolving: SourceLocalDateTime(date: localDate), in: nativeTimeZone, precision: .day)
  }

  /// Shown before any plaintext copy of the ledger leaves the app (LA-004).
  nonisolated package static let plaintextExportWarning = (
    title: "This copy is not encrypted",
    message:
      "Anyone who can open the file can read every account, amount, and note in it. Store it somewhere only you can reach, such as an encrypted disk."
  )

  /// Writes an exact 1:1 backup and returns the SHA-256 hex digest of its bytes.
  @discardableResult
  public func backupCanonicalLedger(to destination: URL) throws -> String {
    guard let source = ledgerURL ?? canonicalURL else {
      throw LedgerApplication.Error.invalidCommand
    }
    guard source.standardizedFileURL != destination.standardizedFileURL else {
      throw LedgerApplication.Error.invalidCommand
    }
    do {
      guard let store = mutableStore ?? openedStore else {
        throw LedgerApplication.Error.invalidCommand
      }
      let digest = try store.backupCanonicalDatabase(to: destination)
      lastFailure = nil
      return digest
    } catch LedgerStore.Error.backupPublicationCompleted {
      throw LedgerStore.Error.backupPublicationCompleted
    } catch {
      throw LedgerApplication.Error.invalidCommand
    }
  }

  public func exportPortablePackage(to destination: URL) throws {
    guard destination.isFileURL, !FileManager.default.fileExists(atPath: destination.path) else {
      throw LedgerApplication.Error.invalidCommand
    }
    let exported = try exportPackage()
    let data = try LedgerPortablePackageFile.encode(
      manifest: exported.manifest, payload: exported.payload)
    do {
      try LedgerPortablePackageFile.publish(data, to: destination)
    } catch {
      throw LedgerApplication.Error.invalidCommand
    }
  }

  public func restoreCanonicalBackup(from source: URL, to destination: URL) throws {
    guard source.standardizedFileURL != destination.standardizedFileURL else {
      throw LedgerApplication.Error.invalidCommand
    }
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw LedgerApplication.Error.invalidCommand
    }
    let sourceStore = try LedgerStore.openReadOnly(at: source)
    try sourceStore.backupCanonicalDatabase(to: destination)
    openLedger(destination)
  }

  public func restorePortablePackage(from source: URL, to destination: URL) throws {
    guard source.isFileURL, destination.isFileURL,
      source.standardizedFileURL != destination.standardizedFileURL,
      !FileManager.default.fileExists(atPath: destination.path)
    else { throw LedgerApplication.Error.invalidCommand }
    let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw LedgerApplication.Error.invalidCommand
    }
    let data: Data
    do { data = try Data(contentsOf: source, options: .mappedIfSafe) }
    catch { throw LedgerApplication.Error.invalidCommand }
    let package: (manifest: LedgerExportManifest, payload: Data)
    do { package = try LedgerPortablePackageFile.decode(data) }
    catch { throw LedgerApplication.Error.invalidCommand }
    try createLedger(from: package, at: destination)
  }

  /// Builds a new ledger at `destination` from a package and switches to it. If any step fails,
  /// the half-made file is removed and the open ledger stays as it was.
  private func createLedger(
    from package: (manifest: LedgerExportManifest, payload: Data), at destination: URL
  ) throws {
    guard destination.isFileURL, !FileManager.default.fileExists(atPath: destination.path) else {
      throw LedgerApplication.Error.invalidCommand
    }
    let created = try LedgerStoreLifecycle.create(at: destination)
    do {
      let application = LedgerApplication(store: created.store)
      try application.importPackage(manifest: package.manifest, payload: package.payload)
      let snapshot = try created.store.readSnapshot()
      adoptValidatedLedger(created.store, snapshot: snapshot, at: destination)
    } catch {
      _ = LedgerStoreLifecycle.discardCreated(created, at: destination)
      throw LedgerApplication.Error.invalidCommand
    }
  }

  /// Reads a backup the person picked as a package: either an exact SQLite backup or a
  /// portable package file. Nothing is written.
  public static func incomingPackage(from source: URL) throws
    -> (manifest: LedgerExportManifest, payload: Data)
  {
    if let store = try? LedgerStore.openReadOnly(at: source) {
      return try LedgerApplication(store: store).exportPackage()
    }
    let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw LedgerApplication.Error.invalidCommand
    }
    do {
      return try LedgerPortablePackageFile.decode(
        try Data(contentsOf: source, options: .mappedIfSafe))
    } catch {
      throw LedgerApplication.Error.invalidCommand
    }
  }

  /// What merging `incoming` into the open ledger would add. Nothing is written.
  public func previewMerge(
    _ incoming: (manifest: LedgerExportManifest, payload: Data)
  ) throws -> LedgerMergeSummary {
    try LedgerApplication.mergedPackage(current: try exportPackage(), incoming: incoming).summary
  }

  /// Merges `incoming` into a copy of the open ledger at `destination` and switches to it.
  /// The previous ledger file is left unchanged, so it can be reopened to undo the merge.
  @discardableResult
  public func mergeIntoNewLedger(
    _ incoming: (manifest: LedgerExportManifest, payload: Data), at destination: URL
  ) throws -> LedgerMergeSummary {
    let merged = try LedgerApplication.mergedPackage(
      current: try exportPackage(), incoming: incoming)
    try createLedger(from: (merged.manifest, merged.payload), at: destination)
    return merged.summary
  }

  /// Starts a replacement ledger at `destination` and switches to it. Contents-only keeps the
  /// accounts, categories, tags and templates; complete keeps nothing. The previous ledger file
  /// is left unchanged, so it can be reopened to undo the reset.
  public func resetLedger(_ scope: LedgerResetScope, at destination: URL) throws {
    guard let snapshot else { throw LedgerApplication.Error.invalidCommand }
    try createLedger(
      from: try LedgerApplication.resetPackage(from: snapshot, scope: scope), at: destination)
  }

  /// The words shown before a merge, from counts only.
  package static func mergePreviewMessage(_ summary: LedgerMergeSummary) -> String {
    if summary.isEmpty { return "The open ledger already has everything in this backup." }
    func count(_ value: Int, _ noun: String) -> String? {
      value == 0 ? nil : "\(value) \(noun)\(value == 1 ? "" : "s")"
    }
    let parts = [
      count(summary.addedAccounts, "account"), count(summary.addedCategories, "category"),
      count(summary.addedTransactions, "new transaction"),
      count(summary.addedRevisions - summary.addedTransactions, "edit"),
      count(summary.addedOther, "other record"),
    ].compactMap { $0 }
    return "Merging adds \(parts.joined(separator: ", ")). Where both ledgers changed the same account, category or other record, the open ledger's version is kept."
  }

  package static func mergeFailureMessage(for error: any Swift.Error) -> String {
    if case LedgerMergeError.conflictingHistory(let revisions) = error {
      return
        "The backup and the open ledger edited \(revisions) of the same transactions in different ways, so nothing was merged. Restore the backup as a separate ledger instead."
    }
    return
      "This backup can't be merged. Merging needs ledgers made in Ledger Atlas; imported ledgers can be restored as a separate ledger. Nothing was changed."
  }

  public func createTransaction(
    idempotencyKey: String, draft: LedgerTransactionDraft, createdAt: UTCInstant,
    tags: LedgerTagLinks = .empty
  ) throws -> LedgerTransactionRevision {
    guard let application else { throw LedgerApplication.Error.invalidCommand }
    let revision = try application.createTransaction(
      idempotencyKey: idempotencyKey, draft: draft, createdAt: createdAt, tags: tags)
    snapshot = try application.snapshot()
    return revision
  }

  public func createAccount(_ account: LedgerAccount) throws {
    guard let application else { throw LedgerApplication.Error.invalidCommand }
    try application.createAccount(account)
    snapshot = try application.snapshot()
  }

  public func createAccountGroup(_ group: LedgerAccountGroup) throws {
    guard let application else { throw LedgerApplication.Error.invalidCommand }
    try application.createAccountGroup(group)
    snapshot = try application.snapshot()
  }

  public func updateAccount(_ account: LedgerAccount) throws {
    guard let application else { throw LedgerApplication.Error.invalidCommand }
    try application.updateAccount(account)
    snapshot = try application.snapshot()
  }

  public func updateAccountGroup(_ group: LedgerAccountGroup) throws {
    guard let application else { throw LedgerApplication.Error.invalidCommand }
    try application.updateAccountGroup(group)
    snapshot = try application.snapshot()
  }

  public func tombstoneAccount(_ accountID: String) throws {
    guard let application else { throw LedgerApplication.Error.invalidCommand }
    try application.tombstoneAccount(accountID)
    snapshot = try application.snapshot()
  }

  public func createCategory(_ category: LedgerCategory) throws {
    guard let application else { throw LedgerApplication.Error.invalidCommand }
    try application.createCategory(category)
    snapshot = try application.snapshot()
  }

  public func updateCategory(_ category: LedgerCategory) throws {
    guard let application else { throw LedgerApplication.Error.invalidCommand }
    try application.updateCategory(category)
    snapshot = try application.snapshot()
  }

  public func tombstoneCategory(_ categoryID: String) throws {
    guard let application else { throw LedgerApplication.Error.invalidCommand }
    try application.tombstoneCategory(categoryID)
    snapshot = try application.snapshot()
  }

  public func createTag(_ tag: LedgerTag) throws {
    guard let application else { throw LedgerApplication.Error.invalidCommand }
    try application.createTag(tag)
    snapshot = try application.snapshot()
    lastFailure = nil
  }

  public func updateTag(_ tag: LedgerTag) throws {
    guard let application else { throw LedgerApplication.Error.invalidCommand }
    try application.updateTag(tag)
    snapshot = try application.snapshot()
    lastFailure = nil
  }

  public func saveTransactionTemplate(_ template: LedgerTransactionTemplate) throws {
    guard let application else { throw LedgerApplication.Error.invalidCommand }
    try application.saveTransactionTemplate(template)
    snapshot = try application.snapshot()
    lastFailure = nil
  }

  public func saveMemo(_ memo: LedgerMemo) throws {
    guard let application else { throw LedgerApplication.Error.invalidCommand }
    try application.saveMemo(memo)
    snapshot = try application.snapshot()
    lastFailure = nil
  }

  // MARK: Receipts

  /// The open ledger's receipts, newest first. Metadata only; bytes load on demand.
  public func receiptAttachments() throws -> [LedgerReceiptAttachment] {
    guard let store = mutableStore ?? openedStore else {
      throw LedgerApplication.Error.invalidCommand
    }
    return try store.receiptAttachments().sorted {
      ($0.createdAt.epochMilliseconds, $0.id) > ($1.createdAt.epochMilliseconds, $1.id)
    }
  }

  /// One receipt's bytes, checked against its stored digest.
  public func receiptBytes(_ receiptID: String) throws -> Data {
    guard let store = mutableStore ?? openedStore else {
      throw LedgerApplication.Error.invalidCommand
    }
    return try store.receiptBytes(receiptID)
  }

  /// Copies a picked file into the ledger. The same image added twice is one receipt.
  @discardableResult
  public func addReceipt(
    from source: URL, linkedTo transactionID: String? = nil, createdAt: UTCInstant
  ) throws -> LedgerReceiptAttachment {
    guard application != nil, let store = mutableStore else {
      throw LedgerApplication.Error.invalidCommand
    }
    let data = try ReceiptFiles.read(source)
    return try store.addReceipt(
      data, origin: LedgerOrigin.macNative(), linkedTo: transactionID, createdAt: createdAt)
  }

  /// Links a receipt to a transaction, or unlinks it with nil.
  public func linkReceipt(_ receiptID: String, to transactionID: String?) throws {
    guard application != nil, let store = mutableStore else {
      throw LedgerApplication.Error.invalidCommand
    }
    try store.linkReceipt(receiptID, to: transactionID)
  }

  /// Removes a receipt from the app. Its bytes stay in the ledger, so older backups and this
  /// ledger's history still match; deleting forever is not part of v1.
  public func removeReceipt(_ receiptID: String) throws {
    guard application != nil, let store = mutableStore else {
      throw LedgerApplication.Error.invalidCommand
    }
    try store.tombstoneReceipt(receiptID)
  }

  /// The only path from a receipt to ledger data. The person reviews the amount, account and
  /// category (text recognition may have suggested the amount) and confirms. This records one
  /// expense and links the receipt to it. The submission ID keys the write, so confirming
  /// twice records one expense.
  public func createExpense(
    fromReceipt receiptID: String, amountLiteral: String, accountID: String,
    categoryID: String?, createdAt: UTCInstant, submissionID: String
  ) throws -> LedgerTransactionRevision {
    guard application != nil, let store = mutableStore,
      try store.receiptAttachments().contains(where: {
        $0.id == receiptID && $0.lifecycle == .active
      })
    else { throw LedgerApplication.Error.invalidCommand }
    let revision = try createNativeTransaction(
      amountLiteral: amountLiteral.trimmingCharacters(in: .whitespacesAndNewlines),
      kind: .expense, accountID: accountID, categoryID: categoryID, note: nil,
      createdAt: createdAt, submissionID: "receipt:\(submissionID)")
    try store.linkReceipt(receiptID, to: revision.transactionID)
    lastFailure = nil
    return revision
  }

  /// Records one transaction from a template, dated today, carrying the template's tags.
  /// The submission ID keys the write, so pressing Use twice records one transaction.
  public func createTransaction(
    fromTemplate templateID: String, createdAt: UTCInstant, submissionID: String
  ) throws -> LedgerTransactionRevision {
    guard application != nil, let snapshot,
      let template = snapshot.transactionTemplates.first(where: { $0.id == templateID })
    else { throw LedgerApplication.Error.invalidCommand }
    let draft = try template.instantiate(
      occurredAt: Self.nativeTemporal(for: createdAt), origin: LedgerOrigin.macNative())
    let activeTagIDs = template.tags.tagIDs.filter { id in
      snapshot.tags.contains { $0.id == id && $0.lifecycle == .active }
    }
    let key = SHA256.hash(data: Data("mac-native-template:\(submissionID)".utf8))
      .map { String(format: "%02x", $0) }.joined()
    let revision = try createTransaction(
      idempotencyKey: key, draft: draft, createdAt: createdAt,
      tags: LedgerTagLinks(activeTagIDs))
    lastFailure = nil
    return revision
  }

  /// Replaces the tags on a transaction by recording a correction with an unchanged draft.
  /// Import receipt markers stay on the original revision, as for any correction.
  public func setTags(
    _ tags: LedgerTagLinks, onTransaction transactionID: String, createdAt: UTCInstant
  ) throws {
    guard let snapshot,
      let current = snapshot.transactions.first(where: { $0.id == transactionID })?
        .currentRevision
    else { throw LedgerApplication.Error.invalidCommand }
    guard snapshot.tags(forRevision: current.id) != tags else { return }
    let draft = try LedgerTransactionDraft(
      effects: current.draft.effects, categoryID: current.draft.categoryID,
      kind: current.draft.kind, occurredAt: current.draft.occurredAt, note: current.draft.note,
      roundingPolicy: current.draft.roundingPolicy,
      sourceLiterals: current.draft.sourceLiterals.filter { !$0.field.hasPrefix("import.") },
      origin: current.draft.origin)
    try edit(
      ledgerURL: ledgerURL ?? canonicalURL ?? URL(fileURLWithPath: "/"),
      transactionID: transactionID, expectedRevisionID: current.id, draft: draft,
      createdAt: createdAt, tags: tags)
    lastFailure = nil
  }

  /// Saves a recorded income, expense or one-to-one transfer as a new Mac-native template,
  /// with the transaction's active tags. The transaction itself is not changed.
  public func saveTemplate(fromTransaction transactionID: String, name: String) throws {
    guard let snapshot,
      let current = snapshot.transactions.first(where: { $0.id == transactionID })?
        .currentRevision
    else { throw LedgerApplication.Error.invalidCommand }
    let active = Set(snapshot.tags.filter { $0.lifecycle == .active }.map(\.id))
    let tags = try LedgerTagLinks(
      snapshot.tags(forRevision: current.id).tagIDs.filter(active.contains))
    let origin = try LedgerOrigin.macNative()
    let key = SHA256.hash(data: Data("ledger-atlas/template/\(UUID().uuidString)".utf8))
      .map { String(format: "%02x", $0) }.joined()
    let template = try LedgerTransactionTemplate(
      capturing: current.draft, tags: tags,
      id: StableLedgerID.transactionTemplate(origin: origin, localKey: key), name: name,
      origin: origin)
    try saveTransactionTemplate(template)
  }

  /// Plain-language message for an annotation save that the store refused.
  package static func annotationFailureMessage(for error: Error, otherwise message: String)
    -> String
  {
    if case LedgerStore.Error.duplicateTagName = error {
      return "Another tag already has that name."
    }
    return message
  }

  public func createTransfer(
    idempotencyKey: String, sourceAccountID: String, destinationAccountID: String,
    sourceAmount: CurrencyAmount, destinationAmount: CurrencyAmount, conversion: LedgerConversion?,
    fee: CurrencyAmount?, feeAccountID: String?, occurredAt: SourceTemporal, origin: LedgerOrigin,
    createdAt: UTCInstant
  ) throws -> (transfer: LedgerTransactionRevision, fee: LedgerTransactionRevision?) {
    guard let application else { throw LedgerApplication.Error.invalidCommand }
    do {
      let result = try application.createTransfer(
        idempotencyKey: idempotencyKey, sourceAccountID: sourceAccountID,
        destinationAccountID: destinationAccountID, sourceAmount: sourceAmount,
        destinationAmount: destinationAmount, conversion: conversion, fee: fee,
        feeAccountID: feeAccountID, occurredAt: occurredAt, origin: origin, createdAt: createdAt)
      snapshot = try application.snapshot()
      return result
    } catch {
      snapshot = try? application.snapshot()
      throw error
    }
  }

  public func createSplit(
    idempotencyKey: String, accountID: String, parentAmount: CurrencyAmount,
    components: [(amount: CurrencyAmount, categoryID: String)], occurredAt: SourceTemporal,
    origin: LedgerOrigin, createdAt: UTCInstant
  ) throws -> [LedgerTransactionRevision] {
    guard let application else { throw LedgerApplication.Error.invalidCommand }
    do {
      let result = try application.createSplit(
        idempotencyKey: idempotencyKey, accountID: accountID, parentAmount: parentAmount,
        components: components, occurredAt: occurredAt, origin: origin, createdAt: createdAt)
      snapshot = try application.snapshot()
      return result
    } catch {
      snapshot = try? application.snapshot()
      throw error
    }
  }

  public func createSplit(
    _ draft: LedgerSplitDraft, createdAt: UTCInstant
  ) throws -> LedgerSplitPurchase {
    guard let application else { throw LedgerApplication.Error.invalidCommand }
    do {
      let purchase = try application.createSplit(draft, createdAt: createdAt)
      snapshot = try application.snapshot()
      return purchase
    } catch {
      snapshot = try? application.snapshot()
      throw error
    }
  }

  public func editSplit(
    _ draft: LedgerSplitDraft, createdAt: UTCInstant
  ) throws -> LedgerSplitPurchase {
    guard let application else { throw LedgerApplication.Error.invalidCommand }
    do {
      let purchase = try application.editSplit(draft, createdAt: createdAt)
      snapshot = try application.snapshot()
      lastFailure = nil
      return purchase
    } catch {
      snapshot = try? application.snapshot()
      throw error
    }
  }

  public func closeSplit(purchaseID: String, createdAt: UTCInstant) throws {
    guard let application else { throw LedgerApplication.Error.invalidCommand }
    do {
      try application.closeSplit(purchaseID: purchaseID, createdAt: createdAt)
      snapshot = try application.snapshot()
      lastFailure = nil
    } catch {
      snapshot = try? application.snapshot()
      throw error
    }
  }

  public func createInstallmentPlan(
    _ plan: LedgerInstallmentPlan, occurredAt: SourceTemporal, createdAt: UTCInstant
  ) throws -> [LedgerTransactionRevision] {
    guard let application else { throw LedgerApplication.Error.invalidCommand }
    let result = try application.createInstallmentPlan(
      plan, occurredAt: occurredAt, createdAt: createdAt)
    snapshot = try application.snapshot()
    return result
  }

  public func createRecurrence(_ rule: LedgerRecurrenceRule) throws {
    guard let application else { throw LedgerApplication.Error.invalidCommand }
    try application.createRecurrence(rule)
    snapshot = try application.snapshot()
  }

  public func createBudget(_ budget: LedgerBudget) throws {
    guard let application else { throw LedgerApplication.Error.invalidCommand }
    try application.createBudget(budget)
    snapshot = try application.snapshot()
  }

  public func updateBudget(_ budget: LedgerBudget) throws {
    guard let application else { throw LedgerApplication.Error.invalidCommand }
    try application.updateBudget(budget)
    snapshot = try application.snapshot()
  }

  public func updateInstallmentPlan(_ plan: LedgerInstallmentPlan) throws {
    guard let application else { throw LedgerApplication.Error.invalidCommand }
    try application.updateInstallmentPlan(plan)
    snapshot = try application.snapshot()
  }

  public func updateRecurrence(_ rule: LedgerRecurrenceRule, scope: LedgerEditScope) throws {
    guard let application else { throw LedgerApplication.Error.invalidCommand }
    try application.updateRecurrence(rule, scope: scope)
    snapshot = try application.snapshot()
  }

  public func generateOccurrences(
    _ rule: LedgerRecurrenceRule, through end: SourceLocalDate, createdAt: UTCInstant
  ) throws {
    guard let application else { throw LedgerApplication.Error.invalidCommand }
    defer { snapshot = (try? application.snapshot()) ?? snapshot }
    guard !rule.paused, rule.lifecycle == .active else { return }
    // LA-028: a long catch-up (a daily rule started years ago) runs as several bounded batches.
    // Each batch is all-or-nothing and repeating one adds nothing, so a failure part-way can
    // simply be retried.
    let dates = try LedgerSchedule.dates(for: rule, through: end)
    let batch = LedgerApplication.maximumOccurrencesPerBatch
    var last = batch - 1
    while last < dates.count - 1 {
      _ = try application.generateOccurrences(rule, through: dates[last], createdAt: createdAt)
      last += batch
    }
    _ = try application.generateOccurrences(rule, through: end, createdAt: createdAt)
  }

  public func exportPackage() throws -> (manifest: LedgerExportManifest, payload: Data) {
    if let application { return try application.exportPackage() }
    guard let ledgerURL else { throw LedgerApplication.Error.invalidCommand }
    let store = try LedgerStore.openReadOnly(at: ledgerURL)
    return try LedgerApplication(store: store).exportPackage()
  }

  public func restorePackage(
    manifest: LedgerExportManifest, payload: Data, into url: URL
  ) throws {
    if let application, ledgerURL == url {
      try application.importPackage(manifest: manifest, payload: payload)
      snapshot = try application.snapshot()
      phase = .imported
      return
    }
    let store = try LedgerStore.openForMutation(at: url)
    let application = LedgerApplication(store: store)
    try application.importPackage(manifest: manifest, payload: payload)
    mutableStore = store
    self.application = application
    snapshot = try application.snapshot()
    canonicalURL = url
    ledgerURL = url
    phase = .imported
  }

  public func edit(
    ledgerURL: URL, transactionID: String, expectedRevisionID: String,
    draft: LedgerTransactionDraft,
    createdAt: UTCInstant, tags: LedgerTagLinks? = nil
  ) throws {
    guard let application else { throw LedgerApplication.Error.invalidCommand }
    do {
      _ = try application.correctTransaction(
        transactionID: transactionID, expectedCurrentRevisionID: expectedRevisionID, draft: draft,
        createdAt: createdAt, tags: tags)
      snapshot = try application.snapshot()
    } catch {
      snapshot = try? application.snapshot()
      throw error
    }
  }

  private static func preservedRows(
    _ records: [LedgerPreservedSourceRecord], tables: Set<String>, title: String
  ) -> [SurfaceRow] {
    var seen: Set<String> = []
    var rows: [SurfaceRow] = []
    for record in records where tables.contains(record.table) {
      let key = record.recordKey.isEmpty ? record.table : "\(record.table):\(record.recordKey)"
      guard seen.insert(key).inserted else { continue }
      rows.append(
        SurfaceRow(
          id: key, title: title,
          detail: record.reasonCode.isEmpty ? "unmapped source" : record.reasonCode))
    }
    return rows
  }

  private static func checksum(_ url: URL) throws -> String {
    let reader = try LedgerStore.openReadOnly(at: url)
    return try LedgerApplication(store: reader).checksum()
  }

  public func rows(for destination: AppDestination) -> [SurfaceRow] {
    guard let snapshot else { return [] }
    switch destination {
    case .accounts:
      let accounts = snapshot.accounts.map {
        SurfaceRow(
          id: $0.id, title: $0.name, detail: "\($0.currencyUnit) · \($0.lifecycle.rawValue)")
      }
      if !accounts.isEmpty { return accounts }
      return Self.preservedRows(
        snapshot.preservedSource, tables: ["ASSETS", "ZASSETS"], title: "Preserved account")
    case .onboarding:
      return [
        SurfaceRow(
          id: "workspace", title: "Local workspace",
          detail:
            "\(snapshot.accounts.count) accounts · \(snapshot.transactions.count) transactions")
      ]
    case .ledger:
      return snapshot.transactions.map {
        let draft = $0.currentRevision.draft
        let amount =
          draft.effects.first.map { "\($0.amount.amount.rawLiteral) \($0.amount.unitCode)" }
          ?? "0"
        return SurfaceRow(
          id: $0.id, title: draft.kind.rawValue,
          detail: "\(amount) · \($0.currentRevision.lifecycle.rawValue)")
      }
    case .receipts:
      return []
    case .localAccess:
      return []
    case .categories:
      let categories = snapshot.categories.map {
        SurfaceRow(id: $0.id, title: $0.name, detail: $0.kind.rawValue)
      }
      let preserved = Self.preservedRows(
        snapshot.preservedSource, tables: ["ZCATEGORY", "CATEGORY"], title: "Preserved category")
      return categories + preserved
    case .tags:
      return snapshot.tags.map {
        SurfaceRow(id: $0.id, title: $0.name, detail: $0.lifecycle.rawValue)
      }
    case .transfers:
      let transfers = snapshot.transactions.filter { $0.currentRevision.draft.kind == .transfer }
        .map {
          SurfaceRow(id: $0.id, title: "Transfer", detail: $0.currentRevision.draft.kind.rawValue)
        }
      let preserved = Self.preservedRows(
        snapshot.preservedSource, tables: ["INOUTCOME", "ZINOUTCOME"],
        title: "Preserved source record")
      return transfers + preserved
    case .recurrence:
      return snapshot.recurrenceRules.map {
        SurfaceRow(
          id: $0.id, title: $0.frequency.rawValue,
          detail: $0.paused ? "paused" : $0.lifecycle.rawValue)
      }
    case .installments:
      return snapshot.installmentPlans.map {
        SurfaceRow(
          id: $0.id, title: $0.principal.amount.rawLiteral,
          detail: "\($0.completedCount)/\($0.occurrenceCount) · \($0.lifecycle.rawValue)")
      }
    case .budgets:
      return snapshot.budgets.map {
        SurfaceRow(
          id: $0.id, title: $0.name,
          detail: "\($0.amount.amount.rawLiteral) \($0.amount.unitCode)")
      }
    case .insights:
      let unit =
        snapshot.accounts.first?.currencyUnit
        ?? snapshot.transactions.first?.currentRevision.draft.effects.first?.amount.unitCode
        ?? "USD"
      let report = (try? LedgerApplication.report(from: snapshot, unitCode: unit))
      let activity = (report?.rows ?? []).map {
        SurfaceRow(
          id: $0.id, title: $0.label,
          detail: "\($0.amountLiteral) \($0.unitCode) (\($0.count))")
      }
      let inventory = (report?.inventory ?? []).map {
        SurfaceRow(id: $0.id, title: $0.label, detail: "\($0.count)")
      }
      let importedCount = snapshot.transactions.filter {
        $0.currentRevision.draft.origin.label == LedgerOrigin.importedLabel
      }.count
      let nativeCount = snapshot.transactions.filter {
        $0.currentRevision.draft.origin.label == LedgerOrigin.macNativeLabel
      }.count
      let unresolved = review?.unresolvedSemanticCount ?? 0
      var analysis = [
        SurfaceRow(id: "origin-imported", title: "Imported", detail: "\(importedCount)"),
        SurfaceRow(id: "origin-mac-native", title: "Mac-native", detail: "\(nativeCount)"),
        SurfaceRow(
          id: "accounts-count", title: "Accounts", detail: "\(snapshot.accounts.count)"),
        SurfaceRow(
          id: "categories-count", title: "Categories", detail: "\(snapshot.categories.count)"),
        SurfaceRow(
          id: "transactions-count", title: "Transactions",
          detail: "\(snapshot.transactions.count)"),
        SurfaceRow(
          id: "unresolved-types", title: "Unresolved source types",
          detail: "\(unresolved) (lossless certification blocked)"),
      ]
      if let income = report?.rows.first(where: { $0.id == "income" }),
        let expense = report?.rows.first(where: { $0.id == "expense" }),
        let net = try? ExactDecimal(income.amountLiteral).subtracting(
          ExactDecimal(expense.amountLiteral))
      {
        analysis.append(
          SurfaceRow(
            id: "net-activity", title: "Net (income − expense)",
            detail: "\(net.rawLiteral) \(unit)"))
      }
      return activity + inventory + analysis
    case .search:
      return LedgerApplication.search(searchQuery, in: snapshot).map {
        SurfaceRow(
          id: $0.id, title: $0.currentRevision.draft.kind.rawValue,
          detail: $0.currentRevision.draft.note ?? $0.currentRevision.lifecycle.rawValue)
      }
    case .backupRestore:
      let exported = try? exportPackage()
      return [
        SurfaceRow(
          id: "schema", title: "Canonical package",
          detail:
            "\(snapshot.accounts.count) accounts · \(snapshot.transactions.count) transactions"),
        SurfaceRow(
          id: "manifest", title: "Integrity",
          detail: exported.map { "schema \($0.manifest.schemaVersion)" } ?? "unavailable"),
      ]
    case .importReview:
      return summary.rows.map { SurfaceRow(id: $0.label, title: $0.label, detail: $0.value) }
    case .settings:
      return [
        SurfaceRow(
          id: "motion", title: "Reduced motion", detail: reduceMotion ? "on" : "off"),
        SurfaceRow(id: "privacy", title: "Privacy redaction", detail: "enabled"),
      ]
    }
  }
}
