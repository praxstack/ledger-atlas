import CSQLite
import CryptoKit
import Foundation
import LedgerCore

/// A persistence boundary for a canonical SQLite handle opened and pinned by its caller.
/// It deliberately does not open paths, create databases, or apply migrations.
public final class LedgerStore {
  public struct LedgerReadSnapshot: Sendable {
    public let accounts: [LedgerAccount]
    public let accountGroups: [LedgerAccountGroup]
    public let transactions: [LedgerTransactionSnapshot]
    public let revisionHistory: [LedgerTransactionRevision]
    public let undisplayedImportedEventCount: Int
    public let categories: [LedgerCategory]
    public let recurrenceRules: [LedgerRecurrenceRule]
    public let budgets: [LedgerBudget]
    public let installmentPlans: [LedgerInstallmentPlan]
    public let preservedSource: [LedgerPreservedSourceRecord]
    public let tags: [LedgerTag]
    public let transactionTemplates: [LedgerTransactionTemplate]
    public let memos: [LedgerMemo]
    /// Tag links by revision ID. Revisions without tags are absent.
    public let revisionTags: [String: LedgerTagLinks]

    public init(
      accounts: [LedgerAccount], accountGroups: [LedgerAccountGroup] = [],
      transactions: [LedgerTransactionSnapshot],
      revisionHistory: [LedgerTransactionRevision], undisplayedImportedEventCount: Int,
      categories: [LedgerCategory] = [], recurrenceRules: [LedgerRecurrenceRule] = [],
      budgets: [LedgerBudget] = [], installmentPlans: [LedgerInstallmentPlan] = [],
      preservedSource: [LedgerPreservedSourceRecord] = [], tags: [LedgerTag] = [],
      transactionTemplates: [LedgerTransactionTemplate] = [], memos: [LedgerMemo] = [],
      revisionTags: [String: LedgerTagLinks] = [:]
    ) {
      self.accounts = accounts
      self.accountGroups = accountGroups
      self.transactions = transactions
      self.revisionHistory = revisionHistory
      self.undisplayedImportedEventCount = undisplayedImportedEventCount
      self.categories = categories
      self.recurrenceRules = recurrenceRules
      self.budgets = budgets
      self.installmentPlans = installmentPlans
      self.preservedSource = preservedSource
      self.tags = tags
      self.transactionTemplates = transactionTemplates
      self.memos = memos
      self.revisionTags = revisionTags
    }

    /// The tags on a revision, empty when it has none.
    public func tags(forRevision revisionID: String) -> LedgerTagLinks {
      revisionTags[revisionID] ?? .empty
    }
  }

  package struct PortablePackageExportSnapshot: Sendable {
    package let ledger: LedgerReadSnapshot
    package let isRepresentable: Bool
    package let hasImportHistory: Bool
    /// Read in the same transaction as `ledger` when the ledger has import history.
    package let importGraph: LedgerImportGraph?
    /// Imported events with no transaction yet. A package can only carry a fully shown ledger.
    package let unmaterializedEventCount: Int
  }
  public struct SchemaIdentity: Equatable, Sendable {
    public let version: Int
    public let fingerprint: String

    public init(version: Int, fingerprint: String) {
      self.version = version
      self.fingerprint = fingerprint
    }
  }

  public enum Error: Swift.Error, Equatable, Sendable {
    case backupPublicationCompleted
    case incompatibleCanonicalStore
    case categoryCycleDetected
    case categoryHasActiveChildren
    case accountGroupHasActiveAccounts
    /// The transaction changed after the caller read it: the expected revision is no longer
    /// current.  Nothing was written; reread and show the latest revision.
    case revisionConflict
    case duplicateTagName
    /// The import plan has conflicts, or the ledger changed after the plan was made. Nothing
    /// was written; plan the import again.
    case importPlanNotApplicable
    /// Not a JPEG, PNG, HEIC or PDF, empty, or over the per-receipt or per-ledger limit.
    case unsupportedReceipt
    /// The receipt was removed. Removed receipts never change again.
    case receiptRemoved
    case sqliteFailure(code: Int32)
    /// A package with import history needs this Mac to hold the ledger's receipt key, which
    /// iCloud Keychain carries between Macs. Nothing was written.
    case importGraphKeyMissing
    /// A package with import history was written by a different canonical schema. Nothing was
    /// written.
    case importGraphSchemaMismatch
    /// A package with import history did not rebuild the ledger it was exported from. Nothing
    /// was written.
    case importGraphMismatch

    fileprivate var preservesMutationError: Bool {
      switch self {
      case .categoryCycleDetected, .categoryHasActiveChildren, .accountGroupHasActiveAccounts,
        .revisionConflict, .duplicateTagName, .importPlanNotApplicable, .importGraphKeyMissing,
        .importGraphSchemaMismatch, .importGraphMismatch, .unsupportedReceipt, .receiptRemoved:
        true
      default:
        false
      }
    }
  }

  package enum MutationTestPhase: Equatable, Sendable {
    case afterRecoveryJournalAuthenticated
    case afterPinnedOpen
    case afterBeginImmediate
    case afterMutationWrite
    case afterInsertingTransaction
    case afterApplyingExportCore
    case afterReadSnapshotCoreRead
    case afterPortableExportSnapshotRead
  }

  package typealias MutationTestHook = (MutationTestPhase) throws -> Void

  package enum BackupTestPhase: Equatable, Sendable {
    case afterTemporaryFileCreated
    case afterTemporaryFileValidated
    case beforeDestinationPublication
    case afterDestinationCopyBeforeValidation
    case afterDestinationPublished
  }

  package typealias BackupTestHook = (BackupTestPhase) throws -> Void

  public struct Transaction {
    fileprivate let database: OpaquePointer
  }

  public enum MutationStatus: Sendable { case committed, unchanged }

  public struct CreateTransactionRequest: Sendable {
    package let idempotencyKey: String
    package let draft: LedgerTransactionDraft
    package let createdAt: UTCInstant
    package let tags: LedgerTagLinks

    package init(
      idempotencyKey: String, draft: LedgerTransactionDraft, createdAt: UTCInstant,
      tags: LedgerTagLinks = .empty
    ) {
      self.idempotencyKey = idempotencyKey
      self.draft = draft
      self.createdAt = createdAt
      self.tags = tags
    }
  }

  public struct CorrectTransactionRequest: Sendable {
    package let transactionID: String
    package let expectedCurrentRevisionID: String
    package let draft: LedgerTransactionDraft
    package let createdAt: UTCInstant
    /// The new revision's tags. Nil keeps the tags of the revision being corrected.
    package let tags: LedgerTagLinks?

    package init(
      transactionID: String, expectedCurrentRevisionID: String, draft: LedgerTransactionDraft,
      createdAt: UTCInstant, tags: LedgerTagLinks? = nil
    ) {
      self.transactionID = transactionID
      self.expectedCurrentRevisionID = expectedCurrentRevisionID
      self.draft = draft
      self.createdAt = createdAt
      self.tags = tags
    }
  }

  public struct TombstoneTransactionRequest: Sendable {
    package let transactionID: String
    package let expectedCurrentRevisionID: String
    package let createdAt: UTCInstant

    package init(transactionID: String, expectedCurrentRevisionID: String, createdAt: UTCInstant) {
      self.transactionID = transactionID
      self.expectedCurrentRevisionID = expectedCurrentRevisionID
      self.createdAt = createdAt
    }
  }

  public struct MutationResult: Sendable {
    package let status: MutationStatus
    package let revision: LedgerTransactionRevision
  }

  private let database: OpaquePointer
  private let pinnedIdentity: stat?
  private let url: URL?
  private let isMutable: Bool
  private let pinnedWriterRegistration: UnsafeMutableRawPointer?
  private let mutationTestHook: MutationTestHook?

  /// Internal seam for the future pinned canonical opener and typed mutation implementation.
  init(takingOwnershipOfValidatedCanonicalDatabase database: OpaquePointer?) throws {
    guard let database else { throw Error.incompatibleCanonicalStore }
    do {
      try Self.execute("PRAGMA foreign_keys=ON", on: database)
      guard Self.scalarInt("PRAGMA foreign_keys", on: database) == 1 else {
        throw Error.incompatibleCanonicalStore
      }
      try Self.validateCanonicalSchema(on: database)
      try CanonicalLedgerHealth.validate(database)
      self.database = database
      pinnedIdentity = nil
      url = nil
      isMutable = true
      pinnedWriterRegistration = nil
      mutationTestHook = nil
    } catch {
      sqlite3_close(database)
      throw Error.incompatibleCanonicalStore
    }
  }

  deinit {
    if let pinnedWriterRegistration {
      _ = csqlite_close_pinned(database, pinnedWriterRegistration)
    } else {
      sqlite3_close(database)
    }
  }

  public var schemaIdentity: SchemaIdentity {
    .init(version: CanonicalLedgerSchema.version, fingerprint: CanonicalLedgerSchema.fingerprint)
  }

  func performAtomically<T>(_ body: (Transaction) throws -> T) throws -> T {
    try Self.execute("BEGIN IMMEDIATE", on: database)
    do {
      let value = try body(Transaction(database: database))
      try Self.execute("COMMIT", on: database)
      return value
    } catch {
      _ = try? Self.execute("ROLLBACK", on: database)
      throw error
    }
  }

  public static func openReadOnly(at url: URL) throws -> LedgerStore {
    try validateNoSQLiteCompanions(at: url)
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw Error.incompatibleCanonicalStore }
    var identity = stat()
    var atPath = stat()
    guard fstat(descriptor, &identity) == 0, lstat(url.path, &atPath) == 0,
      sameFile(identity, atPath), isSafeCanonicalFile(identity)
    else {
      Darwin.close(descriptor)
      throw Error.incompatibleCanonicalStore
    }
    let sqliteDescriptor = dup(descriptor)
    guard sqliteDescriptor >= 0 else {
      Darwin.close(descriptor)
      throw Error.incompatibleCanonicalStore
    }
    var database: OpaquePointer?
    let uri = "file:/dev/fd/\(sqliteDescriptor)?mode=ro"
    let openResult = sqlite3_open_v2(
      uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX, nil)
    Darwin.close(sqliteDescriptor)
    Darwin.close(descriptor)
    guard openResult == SQLITE_OK, let database, sqlite3_db_readonly(database, "main") == 1 else {
      if database != nil { sqlite3_close(database) }
      throw Error.incompatibleCanonicalStore
    }
    do {
      // HAS_MOVED is not meaningful for a standard VFS opened through a file descriptor.
      // The descriptor was authenticated before opening and the path is revalidated below.
      try validateCanonicalSchema(on: database)
      try CanonicalLedgerHealth.validate(
        database, trustKey: try LedgerReceiptTrust.key(for: url, create: false))
      try validatePath(url, matches: identity)
      try validateNoSQLiteCompanions(at: url)
      return LedgerStore(database: database, identity: identity, url: url)
    } catch {
      sqlite3_close(database)
      throw Error.incompatibleCanonicalStore
    }
  }

  public static func openForMutation(at url: URL) throws -> LedgerStore {
    try openForMutation(at: url, expectedIdentity: nil, testing: nil)
  }

  package static func openForMutation(
    at url: URL, expectedIdentity: stat? = nil,
    testing mutationTestHook: MutationTestHook?
  ) throws -> LedgerStore {
    if let expectedIdentity { try validatePath(url, matches: expectedIdentity) }
    let recoveryJournalDescriptor = try openRecoveryJournal(at: url)
    defer {
      if let recoveryJournalDescriptor { Darwin.close(recoveryJournalDescriptor) }
    }
    try mutationTestHook?(.afterRecoveryJournalAuthenticated)
    let descriptor = Darwin.open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw Error.incompatibleCanonicalStore }
    var identity = stat()
    var atPath = stat()
    guard fstat(descriptor, &identity) == 0, lstat(url.path, &atPath) == 0,
      sameFile(identity, atPath), isSafeCanonicalFile(identity),
      expectedIdentity.map({ sameFile($0, identity) }) ?? true
    else {
      Darwin.close(descriptor)
      throw Error.incompatibleCanonicalStore
    }
    if recoveryJournalDescriptor == nil {
      do {
        let authenticated = try openReadOnlyDatabase(descriptor)
        defer { sqlite3_close(authenticated) }
        try validateCanonicalSchema(on: authenticated)
        try CanonicalLedgerHealth.validate(
          authenticated, trustKey: try LedgerReceiptTrust.key(for: url, create: false))
        try validatePath(url, matches: identity)
        try validateNoSQLiteCompanions(at: url)
      } catch {
        Darwin.close(descriptor)
        throw Error.incompatibleCanonicalStore
      }
    }
    let parentURL = url.deletingLastPathComponent()
    let parentDescriptor = Darwin.open(
      parentURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard parentDescriptor >= 0 else {
      Darwin.close(descriptor)
      throw Error.incompatibleCanonicalStore
    }
    defer { Darwin.close(parentDescriptor) }
    let leaf = url.lastPathComponent
    var atParent = stat()
    guard !leaf.isEmpty,
      fstatat(parentDescriptor, leaf, &atParent, AT_SYMLINK_NOFOLLOW) == 0,
      sameFile(identity, atParent)
    else {
      Darwin.close(descriptor)
      throw Error.incompatibleCanonicalStore
    }
    var retainedIdentity = stat()
    var retainedAtParent = stat()
    guard fstat(descriptor, &retainedIdentity) == 0,
      fstatat(parentDescriptor, leaf, &retainedAtParent, AT_SYMLINK_NOFOLLOW) == 0,
      sameFile(identity, retainedIdentity), sameFile(retainedIdentity, retainedAtParent),
      isSafeCanonicalFile(retainedIdentity),
      expectedIdentity.map({ sameFile($0, retainedIdentity) }) ?? true
    else {
      Darwin.close(descriptor)
      throw Error.incompatibleCanonicalStore
    }
    var database: OpaquePointer?
    var registration: UnsafeMutableRawPointer?
    let openResult = url.path.withCString { path in
      leaf.withCString { leaf in
        csqlite_open_pinned_rw(
          path, descriptor, parentDescriptor, recoveryJournalDescriptor ?? -1, leaf, &database,
          &registration)
      }
    }
    Darwin.close(descriptor)
    guard
      openResult == SQLITE_OK, let database, let registration
    else {
      throw Error.incompatibleCanonicalStore
    }
    do {
      try mutationTestHook?(.afterPinnedOpen)
      try execute("PRAGMA foreign_keys=ON", on: database)
      guard scalarInt("PRAGMA foreign_keys", on: database) == 1 else {
        throw Error.incompatibleCanonicalStore
      }
      try validateCanonicalJournalMode(on: database)
      try validateCanonicalSchema(on: database)
      try CanonicalLedgerHealth.validate(
        database, trustKey: try LedgerReceiptTrust.key(for: url, create: false))
      try validateMutablePath(url, matches: identity)
      try validateNoSQLiteCompanions(at: url)
      return LedgerStore(
        mutableDatabase: database, identity: identity, url: url,
        registration: registration, mutationTestHook: mutationTestHook)
    } catch {
      _ = csqlite_close_pinned(database, registration)
      throw Error.incompatibleCanonicalStore
    }
  }

  public func readSnapshot() throws -> LedgerReadSnapshot {
    do {
      try Self.execute("BEGIN", on: database)
      let snapshot = try readSnapshotContents()
      try Self.execute("COMMIT", on: database)
      if let descriptor = pinnedIdentity, let url {
        if isMutable {
          try Self.validateMutablePath(url, matches: descriptor)
        } else {
          try Self.validatePath(url, matches: descriptor)
        }
        try Self.validateNoSQLiteCompanions(at: url)
      }
      return snapshot
    } catch {
      _ = try? Self.execute("ROLLBACK", on: database)
      throw Error.incompatibleCanonicalStore
    }
  }

  /// The package encoder consumes this one coherent SQLite read view; no export decision may
  /// inspect a later database state.
  package func portablePackageExportSnapshot() throws -> PortablePackageExportSnapshot {
    do {
      try Self.execute("BEGIN", on: database)
      let snapshot = try readSnapshotContents(forPortableExport: true)
      guard
        let importReceiptCount = Self.scalarInt(
          "SELECT count(*) FROM main.import_receipt", on: database)
      else { throw Error.incompatibleCanonicalStore }
      // Legacy preservation metadata lives in ledger_meta, which no package carries.
      guard
        let legacyPreservation = Self.scalarInt(
          "SELECT count(*) FROM main.ledger_meta WHERE key='source_preservation_v1'",
          on: database)
      else { throw Error.incompatibleCanonicalStore }
      let representable =
        try Self.portablePackageExportIsRepresentable(on: database) && legacyPreservation == 0
      let importGraph = importReceiptCount > 0 ? try Self.readImportGraph(on: database) : nil
      guard
        let unmaterialized = Self.scalarInt(
          "SELECT count(*) FROM main.economic_event e WHERE NOT EXISTS (SELECT 1 FROM main.ledger_transaction_source_literal l WHERE l.field IN ('import.eventID', 'import.eventID.debit', 'import.eventID.credit') AND l.literal=e.event_id)",
          on: database)
      else { throw Error.incompatibleCanonicalStore }
      try Self.execute("COMMIT", on: database)
      if let descriptor = pinnedIdentity, let url {
        if isMutable {
          try Self.validateMutablePath(url, matches: descriptor)
        } else {
          try Self.validatePath(url, matches: descriptor)
        }
        try Self.validateNoSQLiteCompanions(at: url)
      }
      return .init(
        ledger: snapshot, isRepresentable: representable,
        hasImportHistory: importReceiptCount > 0, importGraph: importGraph,
        unmaterializedEventCount: unmaterialized)
    } catch {
      _ = try? Self.execute("ROLLBACK", on: database)
      throw Error.incompatibleCanonicalStore
    }
  }

  private func readSnapshotContents(forPortableExport: Bool = false) throws -> LedgerReadSnapshot {
    let snapshot = try CanonicalLedgerHealth.readSnapshot(database)
    try mutationTestHook?(
      forPortableExport ? .afterPortableExportSnapshotRead : .afterReadSnapshotCoreRead)
    let importedCount =
      Self.scalarInt("SELECT count(*) FROM main.economic_event", on: database) ?? -1
    guard importedCount >= 0 else { throw Error.incompatibleCanonicalStore }
    return .init(
      accounts: snapshot.accounts, accountGroups: snapshot.accountGroups,
      transactions: snapshot.transactions,
      revisionHistory: snapshot.revisionHistory,
      undisplayedImportedEventCount: importedCount,
      categories: snapshot.categories,
      recurrenceRules: try Self.loadRecurrenceRules(on: database),
      budgets: try Self.loadBudgets(on: database),
      installmentPlans: try Self.loadInstallmentPlans(on: database),
      preservedSource: try Self.loadPreservedSource(on: database),
      tags: try Self.loadTags(on: database),
      transactionTemplates: try Self.loadTransactionTemplates(on: database),
      memos: try Self.loadMemos(on: database),
      revisionTags: try Self.loadRevisionTags(on: database))
  }

  public func createTransaction(_ request: CreateTransactionRequest) throws -> MutationResult {
    let revision = try preparedRevision(for: request)
    return try mutate { snapshot in
      let result = try Self.insertNew(
        revision, tags: request.tags, in: snapshot, on: database)
      try mutationTestHook?(.afterInsertingTransaction)
      return result
    }
  }

  public func createTransfer(
    transfer: CreateTransactionRequest, fee: CreateTransactionRequest?
  ) throws -> (transfer: MutationResult, fee: MutationResult?) {
    let transferRevision = try preparedRevision(for: transfer)
    let feeRevision = try fee.map { try preparedRevision(for: $0) }
    var feeResult: MutationResult?
    let transferResult = try mutate { snapshot in
      let transferResult = try Self.insertNew(
        transferRevision, tags: transfer.tags, in: snapshot, on: database)
      if let feeRevision, let fee {
        feeResult = try Self.insertNew(feeRevision, tags: fee.tags, in: snapshot, on: database)
        let link = try LedgerTransactionLink(
          id: StableLedgerID.link(
            fromTransactionID: transferRevision.transactionID,
            toTransactionID: feeRevision.transactionID, kind: .related),
          fromTransactionID: transferRevision.transactionID,
          toTransactionID: feeRevision.transactionID, kind: .related)
        try Self.run(
          "INSERT INTO main.ledger_transaction_link(link_id, from_transaction_id, to_transaction_id, kind) VALUES (?, ?, ?, ?) ON CONFLICT(link_id) DO NOTHING",
          values: [
            .text(link.id), .text(link.fromTransactionID), .text(link.toTransactionID),
            .text(link.kind.rawValue),
          ], on: database)
      }
      return transferResult
    }
    return (transferResult, feeResult)
  }

  public func createLinkedTransactions(
    _ requests: [CreateTransactionRequest], linkKind: LedgerTransactionLinkKind
  ) throws -> [MutationResult] {
    let revisions = try requests.map { try preparedRevision(for: $0) }
    var results: [MutationResult] = []
    _ = try mutate { snapshot in
      results = []
      for (revision, request) in zip(revisions, requests) {
        results.append(
          try Self.insertNew(revision, tags: request.tags, in: snapshot, on: database))
      }
      if let parent = revisions.first, revisions.count > 1 {
        for child in revisions.dropFirst() {
          let link = try LedgerTransactionLink(
            id: StableLedgerID.link(
              fromTransactionID: parent.transactionID, toTransactionID: child.transactionID,
              kind: linkKind),
            fromTransactionID: parent.transactionID, toTransactionID: child.transactionID,
            kind: linkKind)
          try Self.run(
            "INSERT INTO main.ledger_transaction_link(link_id, from_transaction_id, to_transaction_id, kind) VALUES (?, ?, ?, ?) ON CONFLICT(link_id) DO NOTHING",
            values: [
              .text(link.id), .text(link.fromTransactionID), .text(link.toTransactionID),
              .text(link.kind.rawValue),
            ], on: database)
        }
      }
      guard let first = results.first else { throw Error.incompatibleCanonicalStore }
      return first
    }
    return results
  }

  private func preparedRevision(for request: CreateTransactionRequest) throws
    -> LedgerTransactionRevision
  {
    let transactionID = try StableLedgerID.transaction(
      origin: request.draft.origin, localKey: request.idempotencyKey)
    return try makeRevision(
      transactionID: transactionID, number: 1, predecessorID: nil, draft: request.draft,
      lifecycle: .active, createdAt: request.createdAt)
  }

  private static func insertNew(
    _ revision: LedgerTransactionRevision, tags: LedgerTagLinks = .empty,
    in snapshot: LedgerReadSnapshot, on database: OpaquePointer
  ) throws -> MutationResult {
    // A repeated submission (same idempotency key and content) returns what is stored, even
    // when it arrives later with a newer timestamp. Its tags must match too.
    if let existing = snapshot.revisionHistory.first(where: { $0.id == revision.id }) {
      guard sameSubmission(existing, revision),
        try loadRevisionTags(on: database)[revision.id] ?? .empty == tags
      else { throw Error.incompatibleCanonicalStore }
      return .init(status: .unchanged, revision: existing)
    }
    guard !snapshot.transactions.contains(where: { $0.id == revision.transactionID }) else {
      throw Error.incompatibleCanonicalStore
    }
    try Self.ensureOrigin(revision.draft.origin, on: database)
    try validateReferences(revision, in: snapshot, on: database)
    try run(
      "INSERT INTO main.ledger_transaction(transaction_id, current_revision_id) VALUES (?, ?)",
      values: [.text(revision.transactionID), .text(revision.id)], on: database)
    try insert(revision, on: database)
    try writeRevisionTags(tags, revisionID: revision.id, previous: .empty, on: database)
    return .init(status: .committed, revision: revision)
  }

  /// Two revisions record the same submission when everything but the clock reading matches.
  private static func sameSubmission(
    _ lhs: LedgerTransactionRevision, _ rhs: LedgerTransactionRevision
  ) -> Bool {
    lhs.id == rhs.id && lhs.transactionID == rhs.transactionID && lhs.revision == rhs.revision
      && lhs.predecessorID == rhs.predecessorID && lhs.draft == rhs.draft
      && lhs.lifecycle == rhs.lifecycle
  }

  public func correctTransaction(_ request: CorrectTransactionRequest) throws -> MutationResult {
    try mutate { snapshot in try applyCorrection(request, in: snapshot) }
  }

  /// Corrects several transactions in one database transaction: all are written or none is.
  /// Used for groups such as a split purchase, whose lines must stay consistent.
  public func correctLinkedTransactions(_ requests: [CorrectTransactionRequest]) throws
    -> [MutationResult]
  {
    guard !requests.isEmpty,
      Set(requests.map(\.transactionID)).count == requests.count
    else { throw Error.incompatibleCanonicalStore }
    var results: [MutationResult] = []
    _ = try mutate { snapshot in
      results = try requests.map { try applyCorrection($0, in: snapshot) }
      return results[0]
    }
    return results
  }

  private func applyCorrection(
    _ request: CorrectTransactionRequest, in snapshot: LedgerReadSnapshot
  ) throws -> MutationResult {
    let predecessor = try Self.predecessor(
      transactionID: request.transactionID, revisionID: request.expectedCurrentRevisionID,
      in: snapshot)
    guard predecessor.lifecycle == .active, request.createdAt >= predecessor.createdAt else {
      throw Error.incompatibleCanonicalStore
    }
    guard request.draft.origin == predecessor.draft.origin else {
      throw Error.incompatibleCanonicalStore
    }
    let revision = try makeRevision(
      transactionID: request.transactionID, number: predecessor.revision + 1,
      predecessorID: predecessor.id,
      draft: request.draft, lifecycle: .active, createdAt: request.createdAt)
    let storedTags = try Self.loadRevisionTags(on: database)
    let previousTags = storedTags[predecessor.id] ?? .empty
    let tags = previousTags.carriedForward(replacing: request.tags)
    if let existing = snapshot.revisionHistory.first(where: { $0.id == revision.id }) {
      guard Self.sameSubmission(existing, revision), storedTags[existing.id] ?? .empty == tags
      else { throw Error.revisionConflict }
      return .init(status: .unchanged, revision: existing)
    }
    guard
      snapshot.transactions.first(where: { $0.id == request.transactionID })?.currentRevision.id
        == predecessor.id
    else {
      throw Error.revisionConflict
    }
    try Self.validateReferences(revision, in: snapshot, on: database)
    try Self.insert(revision, on: database)
    try Self.writeRevisionTags(
      tags, revisionID: revision.id, previous: previousTags, on: database)
    try Self.run(
      "UPDATE main.ledger_transaction SET current_revision_id=? WHERE transaction_id=? AND current_revision_id=?",
      values: [.text(revision.id), .text(request.transactionID), .text(predecessor.id)],
      on: database)
    guard sqlite3_changes(database) == 1 else { throw Error.incompatibleCanonicalStore }
    return .init(status: .committed, revision: revision)
  }

  public func tombstoneTransaction(_ request: TombstoneTransactionRequest) throws -> MutationResult
  {
    try mutate { snapshot in try applyTombstone(request, in: snapshot) }
  }

  /// Closes several transactions in one database transaction: all are closed or none is.
  public func tombstoneLinkedTransactions(_ requests: [TombstoneTransactionRequest]) throws
    -> [MutationResult]
  {
    guard !requests.isEmpty,
      Set(requests.map(\.transactionID)).count == requests.count
    else { throw Error.incompatibleCanonicalStore }
    var results: [MutationResult] = []
    _ = try mutate { snapshot in
      results = try requests.map { try applyTombstone($0, in: snapshot) }
      return results[0]
    }
    return results
  }

  private func applyTombstone(
    _ request: TombstoneTransactionRequest, in snapshot: LedgerReadSnapshot
  ) throws -> MutationResult {
    let predecessor = try Self.predecessor(
      transactionID: request.transactionID, revisionID: request.expectedCurrentRevisionID,
      in: snapshot)
    guard predecessor.lifecycle == .active, request.createdAt >= predecessor.createdAt else {
      throw Error.incompatibleCanonicalStore
    }
    let revision = try makeRevision(
      transactionID: request.transactionID, number: predecessor.revision + 1,
      predecessorID: predecessor.id,
      draft: predecessor.draft, lifecycle: .tombstoned, createdAt: request.createdAt)
    let previousTags = try Self.loadRevisionTags(on: database)[predecessor.id] ?? .empty
    if let existing = snapshot.revisionHistory.first(where: { $0.id == revision.id }) {
      guard Self.sameSubmission(existing, revision) else { throw Error.revisionConflict }
      return .init(status: .unchanged, revision: existing)
    }
    guard
      snapshot.transactions.first(where: { $0.id == request.transactionID })?.currentRevision.id
        == predecessor.id
    else {
      throw Error.revisionConflict
    }
    try Self.insert(revision, on: database)
    // A tombstone keeps the labels it had, so history reads the same either way.
    try Self.writeRevisionTags(
      previousTags, revisionID: revision.id, previous: previousTags, on: database)
    try Self.run(
      "UPDATE main.ledger_transaction SET current_revision_id=? WHERE transaction_id=? AND current_revision_id=?",
      values: [.text(revision.id), .text(request.transactionID), .text(predecessor.id)],
      on: database)
    guard sqlite3_changes(database) == 1 else { throw Error.incompatibleCanonicalStore }
    return .init(status: .committed, revision: revision)
  }

  public func createAccount(_ account: LedgerAccount) throws {
    _ = try mutate { snapshot in
      if snapshot.accounts.contains(where: { $0.id == account.id }) {
        guard snapshot.accounts.contains(where: { $0 == account }) else {
          throw Error.incompatibleCanonicalStore
        }
        return try Self.placeholderResult(origin: account.origin, status: .unchanged)
      }
      try Self.ensureAccountGroup(account.groupID, in: snapshot)
      try Self.ensureOrigin(account.origin, on: database)
      try Self.run(
        "INSERT INTO main.ledger_account(account_id, name, currency_unit, origin_id, lifecycle) VALUES (?, ?, ?, ?, ?)",
        values: [
            .text(account.id), .text(account.name), .text(account.currencyUnit),
            .text(account.origin.id), .text(account.lifecycle.rawValue),
          ], on: database)
      try Self.writeAccountPreferences(account, on: database)
      return try Self.placeholderResult(origin: account.origin)
    }
  }

  public func createAccountGroup(_ group: LedgerAccountGroup) throws {
    _ = try mutate { snapshot in
      if let existing = snapshot.accountGroups.first(where: { $0.id == group.id }) {
        guard existing == group else { throw Error.incompatibleCanonicalStore }
        return try Self.placeholderResult(origin: try LedgerOrigin.macNative(), status: .unchanged)
      }
      try Self.run(
        "INSERT INTO main.ledger_account_group(group_id, name, display_order, lifecycle) VALUES (?, ?, ?, ?)",
        values: [
          .text(group.id), .text(group.name), .int(group.displayOrder),
          .text(group.lifecycle.rawValue),
        ], on: database)
      return try Self.placeholderResult(origin: try LedgerOrigin.macNative())
    }
  }

  public func updateAccount(_ account: LedgerAccount) throws {
    _ = try mutate { snapshot in
      guard let existing = snapshot.accounts.first(where: { $0.id == account.id }),
        existing.origin == account.origin,
        existing.currencyUnit == account.currencyUnit
      else { throw Error.incompatibleCanonicalStore }
      try Self.ensureAccountGroup(account.groupID, in: snapshot)
      try Self.run(
        "UPDATE main.ledger_account SET name=?, lifecycle=? WHERE account_id=?",
        values: [.text(account.name), .text(account.lifecycle.rawValue), .text(account.id)],
        on: database)
      try Self.writeAccountPreferences(account, on: database)
      return try Self.placeholderResult(origin: account.origin)
    }
  }

  public func updateAccountGroup(_ group: LedgerAccountGroup) throws {
    _ = try mutate { snapshot in
      guard snapshot.accountGroups.contains(where: { $0.id == group.id }) else {
        throw Error.incompatibleCanonicalStore
      }
      if group.lifecycle == .tombstoned,
        snapshot.accounts.contains(where: { $0.groupID == group.id && $0.lifecycle == .active })
      {
        throw Error.accountGroupHasActiveAccounts
      }
      try Self.run(
        "UPDATE main.ledger_account_group SET name=?, display_order=?, lifecycle=? WHERE group_id=?",
        values: [
          .text(group.name), .int(group.displayOrder), .text(group.lifecycle.rawValue),
          .text(group.id),
        ], on: database)
      return try Self.placeholderResult(origin: try LedgerOrigin.macNative())
    }
  }

  public func tombstoneAccount(_ accountID: String) throws {
    _ = try mutate { snapshot in
      guard let account = snapshot.accounts.first(where: { $0.id == accountID }) else {
        throw Error.incompatibleCanonicalStore
      }
      try Self.run(
        "UPDATE main.ledger_account SET lifecycle=? WHERE account_id=?",
        values: [.text(LedgerLifecycleState.tombstoned.rawValue), .text(account.id)],
        on: database)
      return try Self.placeholderResult(origin: account.origin)
    }
  }

  public func createCategory(_ category: LedgerCategory) throws {
    _ = try mutate { snapshot in
      if let existing = snapshot.categories.first(where: { $0.id == category.id }) {
        guard existing == category else { throw Error.incompatibleCanonicalStore }
        return try Self.placeholderResult(origin: category.origin, status: .unchanged)
      }
      try Self.ensureCategoryParent(category, in: snapshot)
      try Self.ensureOrigin(category.origin, on: database)
      try Self.run(
        "INSERT INTO main.ledger_category(category_id, name, kind, origin_id, lifecycle) VALUES (?, ?, ?, ?, ?)",
        values: [
            .text(category.id), .text(category.name), .text(category.kind.rawValue),
            .text(category.origin.id), .text(category.lifecycle.rawValue),
          ], on: database)
      try Self.writeCategoryTree(category, on: database)
      return try Self.placeholderResult(origin: category.origin)
    }
  }

  public func updateCategory(_ category: LedgerCategory) throws {
    _ = try mutate { snapshot in
      guard let existing = snapshot.categories.first(where: { $0.id == category.id }),
        existing.origin == category.origin, existing.kind == category.kind
      else { throw Error.incompatibleCanonicalStore }
      try Self.ensureCategoryParent(category, in: snapshot)
      try Self.ensureCategoryMutation(category, in: snapshot)
      try Self.run(
        "UPDATE main.ledger_category SET name=?, lifecycle=? WHERE category_id=?",
        values: [.text(category.name), .text(category.lifecycle.rawValue), .text(category.id)],
        on: database)
      try Self.writeCategoryTree(category, on: database)
      return try Self.placeholderResult(origin: category.origin)
    }
  }

  public func tombstoneCategory(_ categoryID: String) throws {
    _ = try mutate { snapshot in
      guard let category = snapshot.categories.first(where: { $0.id == categoryID }) else {
        throw Error.incompatibleCanonicalStore
      }
      let replacement = try LedgerCategory(
        id: category.id, name: category.name, kind: category.kind, origin: category.origin,
        lifecycle: .tombstoned, parentID: category.parentID,
        displayOrder: category.displayOrder, hidden: category.hidden)
      try Self.ensureCategoryMutation(replacement, in: snapshot)
      try Self.run(
        "UPDATE main.ledger_category SET lifecycle=? WHERE category_id=?",
        values: [.text(LedgerLifecycleState.tombstoned.rawValue), .text(category.id)],
        on: database)
      return try Self.placeholderResult(origin: category.origin)
    }
  }

  public func persistLink(_ link: LedgerTransactionLink) throws {
    _ = try mutate { _ in
      try Self.run(
        "INSERT INTO main.ledger_transaction_link(link_id, from_transaction_id, to_transaction_id, kind) VALUES (?, ?, ?, ?) ON CONFLICT(link_id) DO NOTHING",
        values: [
          .text(link.id), .text(link.fromTransactionID), .text(link.toTransactionID),
          .text(link.kind.rawValue),
        ], on: database)
      return try Self.placeholderResult(
        origin: LedgerOrigin(id: String(repeating: "1", count: 64), label: "link"))
    }
  }

  public func persistBudget(_ budget: LedgerBudget) throws {
    _ = try mutate { _ in
      try Self.writeBudget(budget, on: database)
      return try Self.placeholderResult(origin: budget.origin)
    }
  }

  public func persistRecurrence(_ rule: LedgerRecurrenceRule) throws {
    _ = try mutate { _ in
      try Self.writeRecurrence(rule, on: database)
      return try Self.placeholderResult(origin: rule.origin)
    }
  }

  public func persistInstallment(_ plan: LedgerInstallmentPlan) throws {
    _ = try mutate { _ in
      try Self.writeInstallment(plan, on: database)
      return try Self.placeholderResult(origin: plan.origin)
    }
  }

  public func createInstallment(
    _ requests: [CreateTransactionRequest], plan: LedgerInstallmentPlan
  ) throws -> [MutationResult] {
    let revisions = try requests.map { try preparedRevision(for: $0) }
    var results: [MutationResult] = []
    _ = try mutate { snapshot in
      results = []
      for (revision, request) in zip(revisions, requests) {
        results.append(
          try Self.insertNew(revision, tags: request.tags, in: snapshot, on: database))
        try mutationTestHook?(.afterInsertingTransaction)
      }
      if let parent = revisions.first, revisions.count > 1 {
        for child in revisions.dropFirst() {
          let link = try LedgerTransactionLink(
            id: StableLedgerID.link(
              fromTransactionID: parent.transactionID, toTransactionID: child.transactionID,
              kind: .installment),
            fromTransactionID: parent.transactionID, toTransactionID: child.transactionID,
            kind: .installment)
          try Self.run(
            "INSERT INTO main.ledger_transaction_link(link_id, from_transaction_id, to_transaction_id, kind) VALUES (?, ?, ?, ?) ON CONFLICT(link_id) DO NOTHING",
            values: [
              .text(link.id), .text(link.fromTransactionID), .text(link.toTransactionID),
              .text(link.kind.rawValue),
            ], on: database)
        }
      }
      try Self.writeInstallment(plan, on: database)
      guard let first = results.first else { throw Error.incompatibleCanonicalStore }
      return first
    }
    return results
  }

  private static func ensureAccountGroup(
    _ groupID: String?, in snapshot: LedgerReadSnapshot
  ) throws {
    guard let groupID else { return }
    guard snapshot.accountGroups.contains(where: { $0.id == groupID && $0.lifecycle == .active })
    else { throw Error.incompatibleCanonicalStore }
  }

  private static func writeAccountPreferences(_ account: LedgerAccount, on database: OpaquePointer)
    throws
  {
    let isDefault = account.groupID == nil && account.displayOrder == 0 && !account.hidden
      && account.includeInTotals && account.variant == .standard
    if isDefault {
      try run(
        "DELETE FROM main.ledger_account_preferences WHERE account_id=?",
        values: [.text(account.id)], on: database)
      return
    }
    try run(
      """
      INSERT INTO main.ledger_account_preferences(
        account_id, group_id, display_order, hidden, include_in_totals, variant
      ) VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(account_id) DO UPDATE SET
        group_id=excluded.group_id, display_order=excluded.display_order,
        hidden=excluded.hidden, include_in_totals=excluded.include_in_totals,
        variant=excluded.variant
      """,
      values: [
        .text(account.id), .optionalText(account.groupID), .int(account.displayOrder),
        .int(account.hidden ? 1 : 0), .int(account.includeInTotals ? 1 : 0),
        .text(account.variant.rawValue),
      ], on: database)
  }

  private static func ensureCategoryParent(
    _ category: LedgerCategory, in snapshot: LedgerReadSnapshot
  ) throws {
    guard let parentID = category.parentID else { return }
    if parentID == category.id { throw Error.categoryCycleDetected }
    guard snapshot.categories.contains(where: {
      $0.id == parentID && $0.lifecycle == .active && !$0.hidden
    })
    else { throw Error.incompatibleCanonicalStore }
    var categories = Dictionary(uniqueKeysWithValues: snapshot.categories.map { ($0.id, $0) })
    categories[category.id] = category
    var visited: Set<String> = []
    var cursor: String? = category.id
    while let id = cursor {
      guard visited.insert(id).inserted else { throw Error.categoryCycleDetected }
      cursor = categories[id]?.parentID
    }
  }

  private static func ensureCategoryMutation(
    _ category: LedgerCategory, in snapshot: LedgerReadSnapshot
  ) throws {
    guard category.lifecycle == .tombstoned || category.hidden else { return }
    let children = Dictionary(grouping: snapshot.categories.compactMap { value in
      value.parentID.map { ($0, value) }
    }, by: { $0.0 }).mapValues { $0.map(\.1) }
    var pending = children[category.id] ?? []
    while let descendant = pending.popLast() {
      if descendant.lifecycle == .active { throw Error.categoryHasActiveChildren }
      pending.append(contentsOf: children[descendant.id] ?? [])
    }
  }

  private static func writeCategoryTree(_ category: LedgerCategory, on database: OpaquePointer)
    throws
  {
    let isDefault = category.parentID == nil && category.displayOrder == 0 && !category.hidden
    if isDefault {
      try run(
        "DELETE FROM main.ledger_category_tree WHERE category_id=?",
        values: [.text(category.id)], on: database)
      return
    }
    try run(
      """
      INSERT INTO main.ledger_category_tree(category_id, parent_category_id, display_order, hidden)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(category_id) DO UPDATE SET
        parent_category_id=excluded.parent_category_id,
        display_order=excluded.display_order, hidden=excluded.hidden
      """,
      values: [
        .text(category.id), .optionalText(category.parentID), .int(category.displayOrder),
        .int(category.hidden ? 1 : 0),
      ], on: database)
  }

  private static func writeBudget(_ budget: LedgerBudget, on database: OpaquePointer) throws {
    try ensureOrigin(budget.origin, on: database)
    try run(
      """
      INSERT INTO main.ledger_budget(
        budget_id, origin_id, name, category_id, currency_unit, amount_literal, period, rollover,
        start_year, start_month, start_day, lifecycle
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(budget_id) DO UPDATE SET
        name=excluded.name, category_id=excluded.category_id,
        currency_unit=excluded.currency_unit, amount_literal=excluded.amount_literal,
        period=excluded.period, rollover=excluded.rollover, lifecycle=excluded.lifecycle
      """,
      values: [
        .text(budget.id), .text(budget.origin.id), .text(budget.name), .text(budget.categoryID),
        .text(budget.amount.unitCode), .text(budget.amount.amount.rawLiteral),
        .text(budget.period.rawValue), .int(budget.rollover ? 1 : 0),
        .int(budget.start.year), .int(budget.start.month), .int(budget.start.day),
        .text(budget.lifecycle.rawValue),
      ], on: database)
  }

  private static func writeRecurrence(_ rule: LedgerRecurrenceRule, on database: OpaquePointer)
    throws
  {
    try ensureOrigin(rule.origin, on: database)
    let zone: (String, String)
    if let identifier = rule.timeZone.ianaIdentifier {
      zone = ("iana", identifier)
    } else if let offset = rule.timeZone.fixedOffsetSeconds {
      zone = ("fixed", String(offset))
    } else {
      throw Error.incompatibleCanonicalStore
    }
    let skipped = rule.skippedDates.map {
      String(format: "%04d-%02d-%02d", $0.year, $0.month, $0.day)
    }.joined(separator: ",")
    try run(
      """
      INSERT INTO main.ledger_recurrence_rule(
        rule_id, origin_id, account_id, category_id, kind, amount_literal, currency_unit,
        frequency, interval, day_of_month, timezone_kind, timezone_value, start_year, start_month,
        start_day, until_year, until_month, until_day, paused, skipped, lifecycle
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(rule_id) DO UPDATE SET
        account_id=excluded.account_id, category_id=excluded.category_id, kind=excluded.kind,
        amount_literal=excluded.amount_literal, currency_unit=excluded.currency_unit,
        frequency=excluded.frequency, interval=excluded.interval,
        day_of_month=excluded.day_of_month, timezone_kind=excluded.timezone_kind,
        timezone_value=excluded.timezone_value, start_year=excluded.start_year,
        start_month=excluded.start_month, start_day=excluded.start_day,
        until_year=excluded.until_year, until_month=excluded.until_month,
        until_day=excluded.until_day, paused=excluded.paused, skipped=excluded.skipped,
        lifecycle=excluded.lifecycle
      """,
      values: [
        .text(rule.id), .text(rule.origin.id), .text(rule.accountID),
        .optionalText(rule.categoryID), .text(rule.kind.rawValue),
        .text(rule.amount.amount.rawLiteral), .text(rule.amount.unitCode),
        .text(rule.frequency.rawValue), .int(rule.interval),
        .optionalInt(rule.dayOfMonth), .text(zone.0), .text(zone.1),
        .int(rule.start.year), .int(rule.start.month), .int(rule.start.day),
        .optionalInt(rule.until?.year), .optionalInt(rule.until?.month),
        .optionalInt(rule.until?.day), .int(rule.paused ? 1 : 0), .text(skipped),
        .text(rule.lifecycle.rawValue),
      ], on: database)
  }

  private static func writeInstallment(_ plan: LedgerInstallmentPlan, on database: OpaquePointer)
    throws
  {
    try ensureOrigin(plan.origin, on: database)
    try run(
      """
      INSERT INTO main.ledger_installment_plan(
        plan_id, origin_id, account_id, category_id, principal_literal, currency_unit,
        occurrence_count, completed_count, lifecycle
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(plan_id) DO UPDATE SET
        completed_count=excluded.completed_count, lifecycle=excluded.lifecycle
      """,
      values: [
        .text(plan.id), .text(plan.origin.id), .text(plan.accountID),
        .optionalText(plan.categoryID), .text(plan.principal.amount.rawLiteral),
        .text(plan.principal.unitCode), .int(plan.occurrenceCount),
        .int(plan.completedCount), .text(plan.lifecycle.rawValue),
      ], on: database)
  }

  public func applyExport(_ package: LedgerCanonicalPackage) throws {
    guard
      (package.formatVersion == LedgerPortablePackageFormat.version
        && package.formatFingerprint == LedgerPortablePackageFormat.fingerprint)
        || (package.formatVersion == LedgerPortablePackageFormat.legacyV1Version
          && package.formatFingerprint == LedgerPortablePackageFormat.legacyV1Fingerprint)
    else { throw Error.incompatibleCanonicalStore }
    if let graph = package.importGraph {
      try applyImportedExport(package, graph: graph)
      return
    }
    try Self.validateProductRows(package, allowingImportProvenance: false)
    _ = try mutate { snapshot in
      try Self.writeProductRows(
        package, snapshot: snapshot, on: database,
        afterCore: { try self.mutationTestHook?(.afterApplyingExportCore) })
      return try Self.placeholderResult(
        origin: package.accounts.first?.origin
          ?? LedgerOrigin(id: String(repeating: "1", count: 64), label: "restore"))
    }
  }

  private static func validateProductRows(
    _ package: LedgerCanonicalPackage, allowingImportProvenance: Bool
  ) throws {
    let origins =
      package.accounts.map(\.origin) + package.categories.map(\.origin)
      + package.revisions.map(\.draft.origin) + package.recurrenceRules.map(\.origin)
      + package.budgets.map(\.origin) + package.installmentPlans.map(\.origin)
      + package.tags.map(\.origin) + package.transactionTemplates.map(\.origin)
      + package.memos.map(\.origin)
    let importedOriginID = String(repeating: "e", count: 64)
    let revisionIDs = Set(package.revisions.map(\.id))
    guard package.preservedSource.isEmpty,
      Set(package.tags.map(\.id)).count == package.tags.count,
      Set(package.transactionTemplates.map(\.id)).count == package.transactionTemplates.count,
      Set(package.memos.map(\.id)).count == package.memos.count,
      package.revisionTags.keys.allSatisfy(revisionIDs.contains),
      (try? LedgerTag.validateActiveNamesAreUnique(package.tags)) != nil,
      Set(package.accounts.map(\.id)).count == package.accounts.count,
      Set(package.accountGroups.map(\.id)).count == package.accountGroups.count,
      Set(package.categories.map(\.id)).count == package.categories.count,
      Set(package.revisions.map(\.id)).count == package.revisions.count,
      Set(package.revisions.map { "\($0.transactionID):\($0.revision)" }).count
        == package.revisions.count,
      Set(package.links.map(\.id)).count == package.links.count,
      Set(package.recurrenceRules.map(\.id)).count == package.recurrenceRules.count,
      Set(package.budgets.map(\.id)).count == package.budgets.count,
      Set(package.installmentPlans.map(\.id)).count == package.installmentPlans.count,
      allowingImportProvenance
        || !origins.contains(where: {
          $0.provenanceID != nil || $0.id == importedOriginID
            || $0.label == LedgerOrigin.importedLabel
        }),
      allowingImportProvenance
        || !package.revisions.contains(where: { revision in
          revision.draft.sourceLiterals.contains {
            $0.provenanceID != nil || $0.field.hasPrefix("import.")
          }
        })
    else { throw Error.incompatibleCanonicalStore }
    let currencyByAccount = Dictionary(
      package.accounts.map { ($0.id, $0.currencyUnit) }, uniquingKeysWith: { first, _ in first })
    guard
      package.transactionTemplates.allSatisfy({ template in
        ([template.accountID] + (template.counterAccountID.map { [$0] } ?? [])).allSatisfy {
          currencyByAccount[$0] == template.amount.unitCode
        }
      })
    else { throw Error.incompatibleCanonicalStore }
    let groupsByID = Dictionary(uniqueKeysWithValues: package.accountGroups.map { ($0.id, $0) })
    guard package.accounts.allSatisfy({ account in
      guard let groupID = account.groupID else { return true }
      guard let group = groupsByID[groupID] else { return false }
      return group.lifecycle == .active || account.lifecycle == .tombstoned
    }) else { throw Error.incompatibleCanonicalStore }
    let categoriesByID = Dictionary(uniqueKeysWithValues: package.categories.map { ($0.id, $0) })
    guard package.categories.allSatisfy({ category in
      guard let parentID = category.parentID else { return true }
      guard let parent = categoriesByID[parentID] else { return false }
      return (parent.lifecycle == .active && !parent.hidden) || category.lifecycle == .tombstoned
    }) else { throw Error.incompatibleCanonicalStore }
    var categoryVisitState: [String: Int] = [:]
    func visit(_ category: LedgerCategory) -> Bool {
      switch categoryVisitState[category.id] {
      case 1: return false
      case 2: return true
      default: break
      }
      categoryVisitState[category.id] = 1
      if let parentID = category.parentID, let parent = categoriesByID[parentID], !visit(parent) {
        return false
      }
      categoryVisitState[category.id] = 2
      return true
    }
    guard package.categories.allSatisfy(visit) else { throw Error.incompatibleCanonicalStore }
  }

  private static func writeProductRows(
    _ package: LedgerCanonicalPackage, snapshot: LedgerReadSnapshot, on database: OpaquePointer,
    afterImportGraph: Bool = false, afterCore: (() throws -> Void)? = nil
  ) throws {
      // After an import graph write, only its own tables may already hold rows.
      let tables = CanonicalLedgerSchema.expectedObjects
        .filter {
          $0.type == "table" && $0.name != "ledger_meta"
            && !(afterImportGraph && LedgerImportGraph.tableNames.contains($0.name))
        }.map(\.name)
      guard snapshot.transactions.isEmpty, snapshot.accounts.isEmpty,
        try !Self.hasRows(in: tables, on: database)
      else {
        throw Error.incompatibleCanonicalStore
      }
      for group in package.accountGroups {
        try Self.run(
          "INSERT INTO main.ledger_account_group(group_id, name, display_order, lifecycle) VALUES (?, ?, ?, ?)",
          values: [
            .text(group.id), .text(group.name), .int(group.displayOrder),
            .text(group.lifecycle.rawValue),
          ], on: database)
      }
      for account in package.accounts { try Self.ensureOrigin(account.origin, on: database) }
      for account in package.accounts {
        try Self.run(
          "INSERT INTO main.ledger_account(account_id, name, currency_unit, origin_id, lifecycle) VALUES (?, ?, ?, ?, ?)",
          values: [
            .text(account.id), .text(account.name), .text(account.currencyUnit),
            .text(account.origin.id), .text(account.lifecycle.rawValue),
          ], on: database)
        if !afterImportGraph { try Self.writeAccountPreferences(account, on: database) }
      }
      var pendingCategories = package.categories
      var insertedCategoryIDs: Set<String> = []
      while !pendingCategories.isEmpty {
        let ready = pendingCategories.filter {
          $0.parentID == nil || insertedCategoryIDs.contains($0.parentID!)
        }
        guard !ready.isEmpty else { throw Error.incompatibleCanonicalStore }
        for category in ready {
          try Self.ensureOrigin(category.origin, on: database)
          try Self.run(
            "INSERT INTO main.ledger_category(category_id, name, kind, origin_id, lifecycle) VALUES (?, ?, ?, ?, ?)",
            values: [
              .text(category.id), .text(category.name), .text(category.kind.rawValue),
              .text(category.origin.id), .text(category.lifecycle.rawValue),
            ], on: database)
          if !afterImportGraph { try Self.writeCategoryTree(category, on: database) }
          insertedCategoryIDs.insert(category.id)
        }
        pendingCategories.removeAll { insertedCategoryIDs.contains($0.id) }
      }
      let grouped = Dictionary(grouping: package.revisions, by: \.transactionID)
      for (transactionID, revisions) in grouped {
        let ordered = revisions.sorted { $0.revision < $1.revision }
        guard let first = ordered.first else { continue }
        try Self.ensureOrigin(first.draft.origin, on: database)
        try Self.run(
          "INSERT INTO main.ledger_transaction(transaction_id, current_revision_id) VALUES (?, ?)",
          values: [.text(transactionID), .text(first.id)], on: database)
        for revision in ordered {
          // An import graph carries the literal rows verbatim, ordinals included.
          try Self.insert(revision, on: database, includingSourceLiterals: !afterImportGraph)
        }
        if let current = ordered.last {
          try Self.run(
            "UPDATE main.ledger_transaction SET current_revision_id=? WHERE transaction_id=?",
            values: [.text(current.id), .text(transactionID)], on: database)
        }
      }
      for link in package.links {
        try Self.run(
          "INSERT INTO main.ledger_transaction_link(link_id, from_transaction_id, to_transaction_id, kind) VALUES (?, ?, ?, ?) ON CONFLICT(link_id) DO NOTHING",
          values: [
            .text(link.id), .text(link.fromTransactionID), .text(link.toTransactionID),
            .text(link.kind.rawValue),
          ], on: database)
      }
      try afterCore?()
      for rule in package.recurrenceRules { try Self.writeRecurrence(rule, on: database) }
      for budget in package.budgets { try Self.writeBudget(budget, on: database) }
      for plan in package.installmentPlans { try Self.writeInstallment(plan, on: database) }
      try Self.writeImportedAnnotations(package, on: database)
  }

  public func materializeImportedEvents() throws {
    _ = try mutate { snapshot in
      try Self.materializeImportedEvents(
        on: database, knownTransactionIDs: Set(snapshot.transactions.map(\.id)))
      return try Self.placeholderResult(
        origin: LedgerOrigin(id: String(repeating: "e", count: 64), label: "imported"))
    }
  }

  package static func materializeImportedEvents(
    on database: OpaquePointer, knownTransactionIDs: Set<String>? = nil,
    categoryIDsByTransactionID: [String: String] = [:]
  ) throws {
    let origin = try LedgerOrigin(id: String(repeating: "e", count: 64), label: "imported")
    try ensureOrigin(origin, on: database)
    var knownAccounts = Set(
      (try load(
        sql: "SELECT account_id FROM main.ledger_account", on: database, map: { $0[0] })))
    let existingTransactions: Set<String>
    if let knownTransactionIDs {
      existingTransactions = knownTransactionIDs
    } else {
      existingTransactions = Set(
        try load(
          sql: "SELECT transaction_id FROM main.ledger_transaction", on: database, map: { $0[0] }))
    }
    let events = try loadEconomicEvents(on: database)
    let pairs = try importedTransferPairs(events: events, on: database)
    func ensureAccount(for event: ImportedEconomicEvent) throws {
      guard !knownAccounts.contains(event.accountID) else { return }
      try run(
        "INSERT INTO main.ledger_account(account_id, name, currency_unit, origin_id, lifecycle) VALUES (?, ?, ?, ?, ?)",
        values: [
          .text(event.accountID),
          .text((try? sourceAccountUID(eventID: event.id, on: database)) ?? event.accountID),
          .text(event.unitCode),
          .text(origin.id), .text(LedgerLifecycleState.active.rawValue),
        ], on: database)
      knownAccounts.insert(event.accountID)
    }
    // Each paired transfer shows as one transaction named by its transfer ID.
    for pair in pairs where !existingTransactions.contains(pair.id) {
      guard !existingTransactions.contains(pair.debit.id),
        !existingTransactions.contains(pair.credit.id)
      else { throw Error.incompatibleCanonicalStore }
      try ensureAccount(for: pair.debit)
      try ensureAccount(for: pair.credit)
      let revision = try LedgerTransactionRevision(
        id: StableLedgerID.revision(transactionID: pair.id, revision: 1),
        transactionID: pair.id, revision: 1, predecessorID: nil,
        draft: LedgerTransactionDraft(
          effects: [
            try LedgerTransactionEffect(
              accountID: pair.debit.accountID, direction: .decrease, amount: pair.debit.amount),
            try LedgerTransactionEffect(
              accountID: pair.credit.accountID, direction: .increase, amount: pair.credit.amount),
          ], categoryID: nil, kind: .transfer, occurredAt: pair.debit.occurredAt,
          sourceLiterals: [
            try LedgerSourceLiteral(field: "import.eventID.debit", literal: pair.debit.id),
            try LedgerSourceLiteral(field: "import.eventID.credit", literal: pair.credit.id),
          ], origin: origin),
        createdAt: UTCInstant(epochMilliseconds: pair.debit.occurredAt.instant.epochMilliseconds))
      try run(
        "INSERT INTO main.ledger_transaction(transaction_id, current_revision_id) VALUES (?, ?)",
        values: [.text(pair.id), .text(revision.id)], on: database)
      try insert(revision, on: database)
    }
    for event in events
    where event.kind != .transfer && !existingTransactions.contains(event.id) {
      try ensureAccount(for: event)
      let categoryID = categoryIDsByTransactionID[event.id]
      if let categoryID {
        guard Self.categoryIsActive(
          categoryID,
          for: event.kind == .income ? .income : .expense,
          on: database)
        else { throw Error.incompatibleCanonicalStore }
      }
      let revision = try LedgerTransactionRevision(
        id: StableLedgerID.revision(transactionID: event.id, revision: 1),
        transactionID: event.id, revision: 1, predecessorID: nil,
        draft: LedgerTransactionDraft(
          effects: [
            try LedgerTransactionEffect(
              accountID: event.accountID, direction: event.direction, amount: event.amount)
          ], categoryID: categoryID, kind: event.kind, occurredAt: event.occurredAt,
          sourceLiterals: [
            try LedgerSourceLiteral(field: "import.eventID", literal: event.id)
          ], origin: origin),
        createdAt: UTCInstant(epochMilliseconds: event.occurredAt.instant.epochMilliseconds))
      try run(
        "INSERT INTO main.ledger_transaction(transaction_id, current_revision_id) VALUES (?, ?)",
        values: [.text(event.id), .text(revision.id)], on: database)
      try insert(revision, on: database)
    }
  }

  private static func loadCategories(on database: OpaquePointer) throws -> [LedgerCategory] {
    try load(
      sql:
        "SELECT c.category_id, c.name, c.kind, c.origin_id, c.lifecycle, o.label, o.provenance_id FROM main.ledger_category c JOIN main.ledger_origin o ON o.origin_id=c.origin_id",
      on: database
    ) { row in
      let origin = try LedgerOrigin(
        id: row[3], label: row[5], provenanceID: row[6].isEmpty ? nil : row[6])
      return try LedgerCategory(
        id: row[0], name: row[1],
        kind: try requireRaw(LedgerCategoryKind.self, row[2]),
        origin: origin, lifecycle: try requireRaw(LedgerLifecycleState.self, row[4]))
    }
  }

  private static func loadRecurrenceRules(on database: OpaquePointer) throws
    -> [LedgerRecurrenceRule]
  {
    try load(
      sql:
        "SELECT r.rule_id, r.origin_id, r.account_id, r.category_id, r.kind, r.amount_literal, r.currency_unit, r.frequency, r.interval, r.day_of_month, r.timezone_kind, r.timezone_value, r.start_year, r.start_month, r.start_day, r.until_year, r.until_month, r.until_day, r.paused, r.skipped, r.lifecycle, o.label, o.provenance_id FROM main.ledger_recurrence_rule r JOIN main.ledger_origin o ON o.origin_id=r.origin_id",
      on: database
    ) { row in
      let origin = try LedgerOrigin(
        id: row[1], label: row[21], provenanceID: row[22].isEmpty ? nil : row[22])
      let zone =
        row[10] == "iana"
        ? try SourceTimeZone(ianaIdentifier: row[11])
        : try SourceTimeZone(fixedOffsetSeconds: try requireInt(row[11]))
      let skipped: [SourceLocalDate]
      if row[19].isEmpty {
        skipped = []
      } else {
        skipped = try row[19].split(separator: ",", omittingEmptySubsequences: false).map {
          token -> SourceLocalDate in
          let parts = token.split(separator: "-", omittingEmptySubsequences: false)
          guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]),
            let day = Int(parts[2])
          else { throw Error.incompatibleCanonicalStore }
          return try SourceLocalDate(year: year, month: month, day: day)
        }
      }
      let until: SourceLocalDate?
      if row[15].isEmpty && row[16].isEmpty && row[17].isEmpty {
        until = nil
      } else if row[15] == "0" && row[16] == "0" && row[17] == "0" {
        until = nil
      } else {
        until = try SourceLocalDate(
          year: try requireInt(row[15]), month: try requireInt(row[16]),
          day: try requireInt(row[17]))
      }
      let dayOfMonth: Int?
      if row[9].isEmpty || row[9] == "0" {
        dayOfMonth = nil
      } else {
        dayOfMonth = try requireInt(row[9])
      }
      return try LedgerRecurrenceRule(
        id: row[0], origin: origin, accountID: row[2],
        categoryID: row[3].isEmpty ? nil : row[3],
        kind: try requireRaw(LedgerTransactionKind.self, row[4]),
        amount: CurrencyAmount(unitCode: row[6], amount: ExactDecimal(row[5])),
        frequency: try requireRaw(LedgerRecurrenceFrequency.self, row[7]),
        interval: try requireInt(row[8]), dayOfMonth: dayOfMonth, timeZone: zone,
        start: try SourceLocalDate(
          year: try requireInt(row[12]), month: try requireInt(row[13]),
          day: try requireInt(row[14])),
        until: until, paused: row[18] == "1", skippedDates: skipped,
        lifecycle: try requireRaw(LedgerLifecycleState.self, row[20]))
    }
  }

  private static func loadBudgets(on database: OpaquePointer) throws -> [LedgerBudget] {
    try load(
      sql:
        "SELECT b.budget_id, b.origin_id, b.name, b.category_id, b.currency_unit, b.amount_literal, b.period, b.rollover, b.start_year, b.start_month, b.start_day, b.lifecycle, o.label, o.provenance_id FROM main.ledger_budget b JOIN main.ledger_origin o ON o.origin_id=b.origin_id",
      on: database
    ) { row in
      try LedgerBudget(
        id: row[0],
        origin: LedgerOrigin(
          id: row[1], label: row[12], provenanceID: row[13].isEmpty ? nil : row[13]),
        name: row[2],
        categoryID: row[3],
        amount: CurrencyAmount(unitCode: row[4], amount: ExactDecimal(row[5])),
        period: try requireRaw(LedgerBudget.Period.self, row[6]), rollover: row[7] == "1",
        start: try SourceLocalDate(
          year: try requireInt(row[8]), month: try requireInt(row[9]),
          day: try requireInt(row[10])),
        lifecycle: try requireRaw(LedgerLifecycleState.self, row[11]))
    }
  }

  private static func loadInstallmentPlans(on database: OpaquePointer) throws
    -> [LedgerInstallmentPlan]
  {
    try load(
      sql:
        "SELECT p.plan_id, p.origin_id, p.account_id, p.category_id, p.principal_literal, p.currency_unit, p.occurrence_count, p.completed_count, p.lifecycle, o.label, o.provenance_id FROM main.ledger_installment_plan p JOIN main.ledger_origin o ON o.origin_id=p.origin_id",
      on: database
    ) { row in
      try LedgerInstallmentPlan(
        id: row[0],
        origin: LedgerOrigin(
          id: row[1], label: row[9], provenanceID: row[10].isEmpty ? nil : row[10]),
        accountID: row[2],
        categoryID: row[3].isEmpty ? nil : row[3],
        principal: CurrencyAmount(unitCode: row[5], amount: ExactDecimal(row[4])),
        occurrenceCount: try requireInt(row[6]), completedCount: try requireInt(row[7]),
        lifecycle: try requireRaw(LedgerInstallmentPlan.Lifecycle.self, row[8]))
    }
  }

  private struct ImportedTransferPair {
    let id: String
    let debit: ImportedEconomicEvent
    let credit: ImportedEconomicEvent
  }

  /// Every imported transfer leg must belong to exactly one pair: a debit leg and a credit leg
  /// in two different accounts. A leg without its partner, or a pair inside one account,
  /// cannot be shown as a transfer honestly, so the store refuses it.
  private static func importedTransferPairs(
    events: [ImportedEconomicEvent], on database: OpaquePointer
  ) throws -> [ImportedTransferPair] {
    let eventsByID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
    let pairs = try load(
      sql:
        "SELECT transfer_id, debit_event_id, credit_event_id FROM main.economic_event_transfer ORDER BY transfer_id",
      on: database
    ) { row -> ImportedTransferPair in
      guard CanonicalIdentifier.isValid(row[0]),
        let debit = eventsByID[row[1]], debit.kind == .transfer, debit.direction == .decrease,
        let credit = eventsByID[row[2]], credit.kind == .transfer,
        credit.direction == .increase, debit.accountID != credit.accountID
      else { throw Error.incompatibleCanonicalStore }
      return ImportedTransferPair(id: row[0], debit: debit, credit: credit)
    }
    let pairedEventIDs = Set(pairs.flatMap { [$0.debit.id, $0.credit.id] })
    guard events.allSatisfy({ $0.kind != .transfer || pairedEventIDs.contains($0.id) }),
      !pairs.contains(where: { eventsByID[$0.id] != nil })
    else { throw Error.incompatibleCanonicalStore }
    return pairs
  }

  private struct ImportedEconomicEvent {
    let id: String
    let accountID: String
    let kind: LedgerTransactionKind
    let direction: LedgerEffectDirection
    let amount: CurrencyAmount
    let unitCode: String
    let occurredAt: SourceTemporal
  }

  private static func requireRaw<T: RawRepresentable>(_ type: T.Type, _ raw: String) throws -> T
  where T.RawValue == String {
    guard let value = T(rawValue: raw) else { throw Error.incompatibleCanonicalStore }
    return value
  }

  private static func requireInt(_ raw: String) throws -> Int {
    guard let value = Int(raw) else { throw Error.incompatibleCanonicalStore }
    return value
  }

  private static func requireInt64(_ raw: String) throws -> Int64 {
    guard let value = Int64(raw) else { throw Error.incompatibleCanonicalStore }
    return value
  }

  private static func sourceAccountUID(eventID: String, on database: OpaquePointer) throws
    -> String?
  {
    try load(
      sql: """
        SELECT CAST(s.payload AS TEXT) FROM event_source_binding b
        JOIN sidecar_reference s ON s.sidecar_id = b.provenance_id AND s.event_id = b.event_id
        WHERE b.event_id = '\(eventID)' AND b.semantic = 'account' LIMIT 1
        """,
      on: database, map: { $0[0] }
    ).first
  }

  private static func loadEconomicEvents(on database: OpaquePointer) throws
    -> [ImportedEconomicEvent]
  {
    try load(
      sql:
        """
        SELECT event_id, account_id, event_kind, amount_literal, currency_unit,
          instant_milliseconds, local_year, local_month, local_day, local_hour, local_minute,
          local_second, local_millisecond, timezone_kind, timezone_value, temporal_precision,
          resolved_offset_seconds
        FROM main.economic_event ORDER BY event_id
        """,
      on: database
    ) { row in
      let kind: LedgerTransactionKind
      let direction: LedgerEffectDirection
      switch row[2] {
      case "income":
        kind = .income
        direction = .increase
      case "expense":
        kind = .expense
        direction = .decrease
      case "transfer_debit":
        kind = .transfer
        direction = .decrease
      case "transfer_credit":
        kind = .transfer
        direction = .increase
      case "adjustment":
        kind = .adjustment
        direction = .increase
      case "adjustment_debit":
        kind = .adjustment
        direction = .decrease
      default:
        throw Error.incompatibleCanonicalStore
      }
      let local = try SourceLocalDateTime(
        date: SourceLocalDate(
          year: try requireInt(row[6]), month: try requireInt(row[7]),
          day: try requireInt(row[8])),
        hour: try requireInt(row[9]), minute: try requireInt(row[10]),
        second: try requireInt(row[11]), millisecond: try requireInt(row[12]))
      let precision = try requireRaw(SourceTemporalPrecision.self, row[15])
      let instant = UTCInstant(epochMilliseconds: try requireInt64(row[5]))
      let occurred: SourceTemporal
      if row[13] == "iana" {
        occurred = try SourceTemporal.validatingPersistedIANA(
          instant: instant, localDateTime: local, identifier: row[14], precision: precision,
          resolvedOffsetSeconds: try requireInt(row[16]))
      } else {
        occurred = try SourceTemporal(
          instant: instant, localDateTime: local,
          timeZone: SourceTimeZone(fixedOffsetSeconds: try requireInt(row[14])),
          precision: precision,
          resolvedOffsetSeconds: try requireInt(row[16]))
      }
      return try ImportedEconomicEvent(
        id: row[0], accountID: row[1], kind: kind, direction: direction,
        amount: CurrencyAmount(unitCode: row[4], amount: ExactDecimal(row[3])),
        unitCode: row[4], occurredAt: occurred)
    }
  }

  private static func load<T>(
    sql: String, on database: OpaquePointer, map: ([String]) throws -> T
  ) throws -> [T] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw Error.incompatibleCanonicalStore
    }
    defer { sqlite3_finalize(statement) }
    var values: [T] = []
    var result = sqlite3_step(statement)
    while result == SQLITE_ROW {
      let columns = Int(sqlite3_column_count(statement))
      var row: [String] = []
      for index in 0..<columns {
        if sqlite3_column_type(statement, Int32(index)) == SQLITE_NULL {
          row.append("")
        } else if sqlite3_column_type(statement, Int32(index)) == SQLITE_INTEGER {
          row.append(String(sqlite3_column_int64(statement, Int32(index))))
        } else {
          row.append(text(statement, column: Int32(index)) ?? "")
        }
      }
      values.append(try map(row))
      result = sqlite3_step(statement)
    }
    guard result == SQLITE_DONE else { throw Error.incompatibleCanonicalStore }
    return values
  }

  public func readPreservedSource() throws -> [LedgerPreservedSourceRecord] {
    try Self.execute("BEGIN", on: database)
    defer { _ = try? Self.execute("COMMIT", on: database) }
    return try Self.loadPreservedSource(on: database)
  }

  package func containsImportHistory() throws -> Bool {
    try Self.execute("BEGIN", on: database)
    do {
      guard let count = Self.scalarInt("SELECT count(*) FROM main.import_receipt", on: database)
      else { throw Error.incompatibleCanonicalStore }
      try Self.execute("COMMIT", on: database)
      return count > 0
    } catch {
      _ = try? Self.execute("ROLLBACK", on: database)
      throw Error.incompatibleCanonicalStore
    }
  }

  package func portablePackageExportIsRepresentable() throws -> Bool {
    try Self.execute("BEGIN", on: database)
    do {
      let result = try Self.portablePackageExportIsRepresentable(on: database)
      try Self.execute("COMMIT", on: database)
      return result
    } catch {
      _ = try? Self.execute("ROLLBACK", on: database)
      throw Error.incompatibleCanonicalStore
    }
  }

  private static func portablePackageExportIsRepresentable(on database: OpaquePointer) throws
    -> Bool
  {
    guard
      let standaloneOriginCount = scalarInt(
        """
        SELECT EXISTS(
          SELECT 1 FROM main.ledger_origin o
          WHERE NOT EXISTS (SELECT 1 FROM main.ledger_account a WHERE a.origin_id=o.origin_id)
            AND NOT EXISTS (SELECT 1 FROM main.ledger_category c WHERE c.origin_id=o.origin_id)
            AND NOT EXISTS (SELECT 1 FROM main.ledger_transaction_revision r WHERE r.origin_id=o.origin_id)
            AND NOT EXISTS (SELECT 1 FROM main.ledger_recurrence_rule r WHERE r.origin_id=o.origin_id)
            AND NOT EXISTS (SELECT 1 FROM main.ledger_budget b WHERE b.origin_id=o.origin_id)
            AND NOT EXISTS (SELECT 1 FROM main.ledger_installment_plan p WHERE p.origin_id=o.origin_id)
            AND NOT EXISTS (SELECT 1 FROM main.ledger_tag t WHERE t.origin_id=o.origin_id)
            AND NOT EXISTS (SELECT 1 FROM main.ledger_transaction_template t WHERE t.origin_id=o.origin_id)
            AND NOT EXISTS (SELECT 1 FROM main.ledger_memo m WHERE m.origin_id=o.origin_id)
            AND NOT EXISTS (SELECT 1 FROM main.ledger_receipt_attachment r WHERE r.origin_id=o.origin_id)
        )
        """, on: database)
    else { throw Error.incompatibleCanonicalStore }
    // The portable package has no receipts section yet, so a ledger with receipts must use the
    // exact canonical backup until the package can carry them.
    guard
      let receiptCount = scalarInt(
        "SELECT count(*) FROM main.ledger_receipt_attachment", on: database)
    else { throw Error.incompatibleCanonicalStore }
    return standaloneOriginCount != 1 && receiptCount == 0
  }

  package func isEmptyForPortablePackageImport() throws -> Bool {
    try Self.execute("BEGIN", on: database)
    do {
      let tables = CanonicalLedgerSchema.expectedObjects
        .filter { $0.type == "table" && $0.name != "ledger_meta" }.map(\.name)
      let empty = try !Self.hasRows(in: tables, on: database)
      try Self.execute("COMMIT", on: database)
      return empty
    } catch {
      _ = try? Self.execute("ROLLBACK", on: database)
      throw Error.incompatibleCanonicalStore
    }
  }

  private static func hasRows(in tables: [String], on database: OpaquePointer) throws -> Bool {
    for table in tables {
      guard let count = scalarInt("SELECT EXISTS(SELECT 1 FROM main.\(table))", on: database)
      else { throw Error.incompatibleCanonicalStore }
      if count == 1 { return true }
    }
    return false
  }

  fileprivate static func loadPreservedSource(on database: OpaquePointer) throws
    -> [LedgerPreservedSourceRecord]
  {
    let metadata = try load(
      sql: "SELECT value FROM main.ledger_meta WHERE key='source_preservation_v1'",
      on: database, map: { $0[0] })
    if let meta = metadata.first {
      guard metadata.count == 1,
        let canonicalCount = scalarInt(
          "SELECT (SELECT count(*) FROM main.receipt_preservation_payload) + (SELECT count(*) FROM main.sidecar_reference)",
          on: database), canonicalCount == 0,
        let data = meta.data(using: .utf8),
        let rows = try JSONSerialization.jsonObject(with: data) as? [[String: String]]
      else { throw Error.incompatibleCanonicalStore }
      return try rows.map { row in
        guard let table = row["table"], let recordKey = row["recordKey"],
          let columnName = row["columnName"], let storageClass = row["storageClass"],
          let encodedPayload = row["payload"], let payload = Data(base64Encoded: encodedPayload),
          let reasonCode = row["reasonCode"]
        else { throw Error.incompatibleCanonicalStore }
        return LedgerPreservedSourceRecord(
          table: table, recordKey: recordKey, columnName: columnName,
          storageClass: storageClass, payload: payload, reasonCode: reasonCode)
      }
    }
    var statement: OpaquePointer?
    let sql = """
      SELECT p.source_table, coalesce(p.source_record_key,''), coalesce(p.source_column_name,''),
        x.storage_class, x.payload
      FROM main.receipt_preservation_payload x
      JOIN main.provenance_reference p ON p.provenance_id = x.provenance_id
      UNION
      SELECT p.source_table, coalesce(p.source_record_key,''),
        coalesce(p.source_column_name,''), s.storage_class, s.payload
      FROM main.sidecar_reference s
      JOIN main.provenance_reference p ON p.provenance_id = s.provenance_id
      ORDER BY 1, 2, 3
      """
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw Error.incompatibleCanonicalStore
    }
    defer { sqlite3_finalize(statement) }
    var rows: [LedgerPreservedSourceRecord] = []
    var result = sqlite3_step(statement)
    while result == SQLITE_ROW {
      let table = text(statement, column: 0) ?? ""
      let recordKey = text(statement, column: 1) ?? ""
      let columnName = text(statement, column: 2) ?? ""
      let storageClass = text(statement, column: 3) ?? ""
      let payload: Data
      if sqlite3_column_type(statement, 4) == SQLITE_NULL {
        payload = Data()
      } else if sqlite3_column_type(statement, 4) == SQLITE_BLOB {
        let count = Int(sqlite3_column_bytes(statement, 4))
        if count == 0 {
          payload = Data()
        } else if let pointer = sqlite3_column_blob(statement, 4) {
          payload = Data(bytes: pointer, count: count)
        } else {
          throw Error.incompatibleCanonicalStore
        }
      } else if sqlite3_column_type(statement, 4) == SQLITE_TEXT {
        payload = Data((text(statement, column: 4) ?? "").utf8)
      } else {
        throw Error.incompatibleCanonicalStore
      }
      rows.append(
        LedgerPreservedSourceRecord(
          table: table, recordKey: recordKey, columnName: columnName, storageClass: storageClass,
          payload: payload, reasonCode: "opaque_sidecar_preserved"))
      result = sqlite3_step(statement)
    }
    guard result == SQLITE_DONE else { throw Error.incompatibleCanonicalStore }
    return rows
  }

  public func semanticChecksum() throws -> String {
    try Self.execute("BEGIN", on: database)
    do {
      let result = try Self.canonicalChecksum(database)
      try Self.execute("COMMIT", on: database)
      return result
    } catch {
      _ = try? Self.execute("ROLLBACK", on: database)
      throw Error.incompatibleCanonicalStore
    }
  }

  /// Publish an exact plaintext copy of the ledger with mode 0600.
  ///
  /// The copy is assembled and validated in the app's temporary folder, then written to
  /// `destination` with an exclusive create. Nothing else is created next to `destination`,
  /// because the App Sandbox only lets the app write the one file the person picked.
  /// - Returns: the lowercase SHA-256 hex digest of the published bytes.
  @discardableResult
  public func backupCanonicalDatabase(to destination: URL) throws -> String {
    try backupCanonicalDatabase(to: destination, testing: nil)
  }

  @discardableResult
  package func backupCanonicalDatabase(
    to destination: URL, staging stagingDirectory: URL? = nil,
    testing backupTestHook: BackupTestHook?
  ) throws -> String {
    guard destination.isFileURL, destination.path.hasPrefix("/") else {
      throw Error.incompatibleCanonicalStore
    }
    let stagingURL = (stagingDirectory ?? FileManager.default.temporaryDirectory)
      .resolvingSymlinksInPath()
    guard stagingURL.isFileURL, stagingURL.path.hasPrefix("/") else {
      throw Error.incompatibleCanonicalStore
    }
    try validateBoundPath()
    try Self.execute("BEGIN", on: database)
    var byteCount: sqlite3_int64 = 0
    let serialized: UnsafeMutablePointer<UInt8>
    let expectedChecksum: String
    do {
      expectedChecksum = try Self.canonicalChecksum(database)
      guard let bytes = sqlite3_serialize(database, "main", &byteCount, 0), byteCount > 0,
        byteCount <= sqlite3_int64(Int.max)
      else { throw Error.incompatibleCanonicalStore }
      serialized = bytes
      try Self.execute("COMMIT", on: database)
    } catch {
      _ = try? Self.execute("ROLLBACK", on: database)
      throw Error.incompatibleCanonicalStore
    }
    defer { sqlite3_free(serialized) }
    let digest = SHA256.hash(
      data: UnsafeRawBufferPointer(start: serialized, count: Int(byteCount))
    ).map { String(format: "%02x", $0) }.joined()

    let parentURL = destination.deletingLastPathComponent()
    let leaf = destination.lastPathComponent
    let parentDescriptor = Darwin.open(
      parentURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard parentDescriptor >= 0, !leaf.isEmpty, leaf != ".", leaf != ".." else {
      if parentDescriptor >= 0 { Darwin.close(parentDescriptor) }
      throw Error.incompatibleCanonicalStore
    }
    defer { Darwin.close(parentDescriptor) }
    let stagingDescriptor = Darwin.open(
      stagingURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard stagingDescriptor >= 0 else { throw Error.incompatibleCanonicalStore }
    defer { Darwin.close(stagingDescriptor) }
    let temporaryLeaf = ".ledger-atlas-backup-\(UUID().uuidString).tmp"
    let descriptor = Darwin.openat(
      stagingDescriptor, temporaryLeaf,
      O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      mode_t(S_IRUSR | S_IWUSR))
    guard descriptor >= 0, fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
      if descriptor >= 0 { Darwin.close(descriptor) }
      throw Error.incompatibleCanonicalStore
    }
    var createdIdentity = stat()
    guard fstat(descriptor, &createdIdentity) == 0, Self.isSafeCanonicalFile(createdIdentity) else {
      Darwin.close(descriptor)
      throw Error.incompatibleCanonicalStore
    }
    var published = false
    defer {
      if !published,
        Self.backupTemporaryIsBound(
          descriptor, createdIdentity: createdIdentity, parentDescriptor: stagingDescriptor,
          temporaryLeaf: temporaryLeaf),
        Self.matchesSerializedPrefix(
          descriptor, serialized: serialized, serializedCount: Int(byteCount)),
        Self.backupTemporaryIsBound(
          descriptor, createdIdentity: createdIdentity, parentDescriptor: stagingDescriptor,
          temporaryLeaf: temporaryLeaf)
      {
        _ = ftruncate(descriptor, 0)
        _ = fsync(descriptor)
        if Self.backupTemporaryIsBound(
          descriptor, createdIdentity: createdIdentity, parentDescriptor: stagingDescriptor,
          temporaryLeaf: temporaryLeaf)
        {
          _ = unlinkat(stagingDescriptor, temporaryLeaf, 0)
        }
        _ = fsync(stagingDescriptor)
      }
      Darwin.close(descriptor)
    }
    try backupTestHook?(.afterTemporaryFileCreated)
    var retainedEmptyIdentity = stat()
    var emptyAtPath = stat()
    guard fstat(descriptor, &retainedEmptyIdentity) == 0,
      Self.sameFile(createdIdentity, retainedEmptyIdentity),
      fstatat(stagingDescriptor, temporaryLeaf, &emptyAtPath, AT_SYMLINK_NOFOLLOW) == 0,
      Self.sameFile(retainedEmptyIdentity, emptyAtPath),
      Self.isSafeCanonicalFile(retainedEmptyIdentity)
    else { throw Error.incompatibleCanonicalStore }

    var offset = 0
    let count = Int(byteCount)
    while offset < count {
      let written = Darwin.write(descriptor, serialized.advanced(by: offset), count - offset)
      guard written > 0 else { throw Error.incompatibleCanonicalStore }
      offset += written
    }
    guard fsync(descriptor) == 0, fstat(descriptor, &createdIdentity) == 0,
      createdIdentity.st_size == byteCount, Self.isSafeCanonicalFile(createdIdentity)
    else {
      throw Error.incompatibleCanonicalStore
    }
    let validationDatabase = try Self.openReadOnlyDatabase(descriptor)
    do {
      try Self.validateCanonicalSchema(on: validationDatabase)
      try CanonicalLedgerHealth.validate(
        validationDatabase,
        trustKey: try self.url.flatMap {
          try LedgerReceiptTrust.key(for: $0, create: false)
        })
      guard try Self.canonicalChecksum(validationDatabase) == expectedChecksum else {
        throw Error.incompatibleCanonicalStore
      }
      sqlite3_close(validationDatabase)
    } catch {
      sqlite3_close(validationDatabase)
      throw Error.incompatibleCanonicalStore
    }
    try backupTestHook?(.afterTemporaryFileValidated)
    var retainedValidatedIdentity = stat()
    var validatedAtPath = stat()
    guard fstat(descriptor, &retainedValidatedIdentity) == 0,
      Self.sameFile(createdIdentity, retainedValidatedIdentity),
      retainedValidatedIdentity.st_size == byteCount,
      fstatat(stagingDescriptor, temporaryLeaf, &validatedAtPath, AT_SYMLINK_NOFOLLOW) == 0,
      Self.sameFile(retainedValidatedIdentity, validatedAtPath),
      Self.matchesSerializedPrefix(
        descriptor, serialized: serialized, serializedCount: Int(byteCount))
    else { throw Error.incompatibleCanonicalStore }
    try backupTestHook?(.beforeDestinationPublication)
    let publishedIdentity = try Self.publishBackupCopy(
      descriptor, createdIdentity: createdIdentity, stagingDescriptor: stagingDescriptor,
      parentDescriptor: parentDescriptor, temporaryLeaf: temporaryLeaf, destinationLeaf: leaf,
      serialized: serialized, serializedCount: Int(byteCount), testing: backupTestHook)
    guard
      Self.backupTemporaryIsBound(
        descriptor, createdIdentity: createdIdentity, parentDescriptor: stagingDescriptor,
        temporaryLeaf: temporaryLeaf)
    else { throw Error.backupPublicationCompleted }
    guard unlinkat(stagingDescriptor, temporaryLeaf, 0) == 0, fsync(stagingDescriptor) == 0 else {
      throw Error.backupPublicationCompleted
    }
    published = true
    do {
      try backupTestHook?(.afterDestinationPublished)
      guard
        Self.backupDestinationIsBound(
          parentDescriptor, leaf: leaf, expectedIdentity: publishedIdentity),
        fsync(parentDescriptor) == 0
      else { throw Error.backupPublicationCompleted }
      try Self.validatePath(destination, matches: publishedIdentity)
      try validateBoundPath()
    } catch {
      throw Error.backupPublicationCompleted
    }
    return digest
  }

  private static func backupTemporaryIsBound(
    _ descriptor: Int32, createdIdentity: stat, parentDescriptor: Int32, temporaryLeaf: String
  ) -> Bool {
    var retained = stat()
    var atPath = stat()
    return fstat(descriptor, &retained) == 0
      && sameInode(retained, createdIdentity)
      && isSafeCanonicalFile(retained)
      && fstatat(parentDescriptor, temporaryLeaf, &atPath, AT_SYMLINK_NOFOLLOW) == 0
      && sameFile(retained, atPath)
      && isSafeCanonicalFile(atPath)
  }

  private static func backupDestinationIsBound(
    _ parentDescriptor: Int32, leaf: String, expectedIdentity: stat
  ) -> Bool {
    var atPath = stat()
    return fstatat(parentDescriptor, leaf, &atPath, AT_SYMLINK_NOFOLLOW) == 0
      && isSafeCanonicalFile(atPath) && sameFile(atPath, expectedIdentity)
  }

  /// Publish a backup by copying bytes from the authenticated temporary descriptor. The final
  /// destination never consumes a replacement that appeared at the temporary pathname.
  private static func publishBackupCopy(
    _ source: Int32, createdIdentity: stat, stagingDescriptor: Int32, parentDescriptor: Int32,
    temporaryLeaf: String, destinationLeaf: String, serialized: UnsafePointer<UInt8>,
    serializedCount: Int, testing backupTestHook: BackupTestHook?
  ) throws -> stat {
    guard
      backupTemporaryIsBound(
        source, createdIdentity: createdIdentity, parentDescriptor: stagingDescriptor,
        temporaryLeaf: temporaryLeaf)
    else { throw Error.incompatibleCanonicalStore }
    let destination = Darwin.openat(
      parentDescriptor, destinationLeaf,
      O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      mode_t(S_IRUSR | S_IWUSR))
    guard destination >= 0 else { throw Error.incompatibleCanonicalStore }
    var destinationIdentity = stat()
    guard fstat(destination, &destinationIdentity) == 0,
      isSafeCanonicalFile(destinationIdentity)
    else {
      Darwin.close(destination)
      _ = unlinkat(parentDescriptor, destinationLeaf, 0)
      _ = fsync(parentDescriptor)
      throw Error.incompatibleCanonicalStore
    }
    do {
      var sourceIdentity = stat()
      guard fstat(source, &sourceIdentity) == 0, isSafeCanonicalFile(sourceIdentity),
        sourceIdentity.st_size == off_t(serializedCount)
      else { throw Error.incompatibleCanonicalStore }
      var offset: off_t = 0
      var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
      while offset < sourceIdentity.st_size {
        let amount = min(buffer.count, Int(sourceIdentity.st_size - offset))
        let readCount = pread(source, &buffer, amount, offset)
        guard readCount == amount else { throw Error.incompatibleCanonicalStore }
        var written = 0
        while written < amount {
          let count = buffer.withUnsafeBytes {
            Darwin.write(destination, $0.baseAddress!.advanced(by: written), amount - written)
          }
          guard count > 0 else { throw Error.incompatibleCanonicalStore }
          written += count
        }
        offset += off_t(amount)
      }
      guard fsync(destination) == 0,
        backupTemporaryIsBound(
          source, createdIdentity: createdIdentity, parentDescriptor: stagingDescriptor,
          temporaryLeaf: temporaryLeaf)
      else { throw Error.incompatibleCanonicalStore }
      try backupTestHook?(.afterDestinationCopyBeforeValidation)
      guard
        matchesSerializedPrefix(
          destination, serialized: serialized, serializedCount: serializedCount)
      else { throw Error.incompatibleCanonicalStore }
      destinationIdentity = try destinationIdentityOf(destination)
      guard isSafeCanonicalFile(destinationIdentity),
        backupDestinationIsBound(
          parentDescriptor, leaf: destinationLeaf, expectedIdentity: destinationIdentity),
        fsync(parentDescriptor) == 0
      else { throw Error.incompatibleCanonicalStore }
      Darwin.close(destination)
      return destinationIdentity
    } catch {
      var atPath = stat()
      if fstatat(parentDescriptor, destinationLeaf, &atPath, AT_SYMLINK_NOFOLLOW) == 0,
        sameInode(atPath, destinationIdentity)
      {
        _ = unlinkat(parentDescriptor, destinationLeaf, 0)
        _ = fsync(parentDescriptor)
      }
      Darwin.close(destination)
      throw error
    }
  }

  private static func destinationIdentityOf(_ descriptor: Int32) throws -> stat {
    var value = stat()
    guard fstat(descriptor, &value) == 0 else { throw Error.incompatibleCanonicalStore }
    return value
  }

  private static func matchesSerializedPrefix(
    _ descriptor: Int32, serialized: UnsafePointer<UInt8>, serializedCount: Int
  ) -> Bool {
    var before = stat()
    guard fstat(descriptor, &before) == 0, isSafeCanonicalFile(before), before.st_size >= 0,
      before.st_size == off_t(serializedCount)
    else { return false }
    var offset = 0
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while offset < Int(before.st_size) {
      let amount = min(buffer.count, Int(before.st_size) - offset)
      let readCount = buffer.withUnsafeMutableBytes {
        pread(descriptor, $0.baseAddress, amount, off_t(offset))
      }
      guard readCount == amount,
        buffer.withUnsafeBytes({
          memcmp($0.baseAddress, serialized.advanced(by: offset), amount) == 0
        })
      else { return false }
      offset += amount
    }
    var after = stat()
    return fstat(descriptor, &after) == 0 && sameFile(before, after)
  }

  private func validateBoundPath() throws {
    guard let pinnedIdentity, let url else { return }
    if isMutable {
      try Self.validateMutablePath(url, matches: pinnedIdentity)
    } else {
      try Self.validatePath(url, matches: pinnedIdentity)
    }
  }

  package func matchesPinnedInode(_ expected: stat) -> Bool {
    pinnedIdentity.map { Self.sameInode($0, expected) } == true
  }

  package static func canonicalChecksum(_ database: OpaquePointer) throws -> String {
    var hasher = SHA256()
    updateChecksum(&hasher, Data("ledger-atlas/canonical-checksum/v1".utf8))
    for sql in CanonicalLedgerSchema.checksumQueries {
      updateChecksum(&hasher, Data(sql.utf8))
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
        let statement
      else { throw Error.incompatibleCanonicalStore }
      defer { sqlite3_finalize(statement) }
      while true {
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { break }
        guard result == SQLITE_ROW else { throw Error.incompatibleCanonicalStore }
        for column in 0..<sqlite3_column_count(statement) {
          switch sqlite3_column_type(statement, column) {
          case SQLITE_NULL:
            updateChecksum(&hasher, Data([0]))
          case SQLITE_INTEGER:
            updateChecksum(&hasher, Data([1]))
            updateChecksum(
              &hasher, Data(String(sqlite3_column_int64(statement, column)).utf8))
          case SQLITE_TEXT:
            updateChecksum(&hasher, Data([2]))
            let count = Int(sqlite3_column_bytes(statement, column))
            if count == 0 {
              updateChecksum(&hasher, Data())
            } else if let bytes = sqlite3_column_text(statement, column) {
              updateChecksum(&hasher, Data(bytes: bytes, count: count))
            } else {
              throw Error.incompatibleCanonicalStore
            }
          case SQLITE_BLOB:
            updateChecksum(&hasher, Data([3]))
            let count = Int(sqlite3_column_bytes(statement, column))
            if count == 0 {
              updateChecksum(&hasher, Data())
            } else if let bytes = sqlite3_column_blob(statement, column) {
              updateChecksum(&hasher, Data(bytes: bytes, count: count))
            } else {
              throw Error.incompatibleCanonicalStore
            }
          default:
            throw Error.incompatibleCanonicalStore
          }
        }
      }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func updateChecksum(_ hasher: inout SHA256, _ data: Data) {
    var length = UInt64(data.count).bigEndian
    withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
    hasher.update(data: data)
  }

  private static func ensureOrigin(_ origin: LedgerOrigin, on database: OpaquePointer) throws {
    if originMatches(origin, on: database) { return }
    try run(
      """
      INSERT INTO main.ledger_origin(origin_id, label, provenance_id) VALUES (?, ?, ?)
      ON CONFLICT(origin_id) DO NOTHING
      """,
      values: [.text(origin.id), .text(origin.label), .optionalText(origin.provenanceID)],
      on: database)
    guard originMatches(origin, on: database) else { throw Error.incompatibleCanonicalStore }
  }

  private static func placeholderResult(
    origin: LedgerOrigin, status: MutationStatus = .committed
  ) throws -> MutationResult {
    let accountID = String(repeating: "a", count: 64)
    let transactionID = try StableLedgerID.transaction(
      origin: origin, localKey: String(repeating: "e", count: 64))
    let draft = try LedgerTransactionDraft(
      effects: [
        try LedgerTransactionEffect(
          accountID: accountID, direction: .increase,
          amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("1")))
      ], categoryID: nil, kind: .adjustment, occurredAt: accountPlaceholderTemporal(),
      origin: origin)
    return .init(
      status: status,
      revision: try LedgerTransactionRevision(
        id: StableLedgerID.revision(transactionID: transactionID, revision: 1),
        transactionID: transactionID, revision: 1, predecessorID: nil, draft: draft,
        createdAt: UTCInstant(epochMilliseconds: 0)))
  }

  private static func accountPlaceholderTemporal() throws -> SourceTemporal {
    try SourceTemporal(
      resolving: SourceLocalDateTime(date: SourceLocalDate(year: 1970, month: 1, day: 1)),
      in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .day)
  }

  private init(database: OpaquePointer, identity: stat, url: URL) {
    self.database = database
    pinnedIdentity = identity
    self.url = url
    isMutable = false
    pinnedWriterRegistration = nil
    mutationTestHook = nil
  }

  private init(
    mutableDatabase database: OpaquePointer, identity: stat, url: URL,
    registration: UnsafeMutableRawPointer, mutationTestHook: MutationTestHook?
  ) {
    self.database = database
    pinnedIdentity = identity
    self.url = url
    isMutable = true
    pinnedWriterRegistration = registration
    self.mutationTestHook = mutationTestHook
  }

  /// `trustIdentity` names the receipt key for a write that adds the ledger's first receipt,
  /// which the file on disk cannot name until the transaction commits.
  package func mutate(
    trustIdentity: String? = nil, _ body: (LedgerReadSnapshot) throws -> MutationResult
  ) throws -> MutationResult {
    try validateMutationIdentity(requiringNoCompanions: true)
    try Self.execute("BEGIN IMMEDIATE", on: database)
    do {
      try mutationTestHook?(.afterBeginImmediate)
      try Self.validateCanonicalSchema(on: database)
      let snapshot = try CanonicalLedgerHealth.readSnapshot(database)
      let result = try body(snapshot)
      try mutationTestHook?(.afterMutationWrite)
      try CanonicalLedgerHealth.validate(
        database,
        trustKey: try self.url.flatMap {
          try LedgerReceiptTrust.key(for: $0, create: false, stableIdentity: trustIdentity)
        }, verifyingReceiptImages: false)
      guard Self.hasNoRows("PRAGMA foreign_key_check", on: database) else {
        throw Error.incompatibleCanonicalStore
      }
      try validateMutationIdentity(requiringNoCompanions: false)
      try Self.execute("COMMIT", on: database)
      return result
    } catch {
      _ = try? Self.execute("ROLLBACK", on: database)
      if let error = error as? Error, error.preservesMutationError { throw error }
      throw Error.incompatibleCanonicalStore
    }
  }

  private func validateMutationIdentity(requiringNoCompanions: Bool) throws {
    guard isMutable, let identity = pinnedIdentity, let url else { return }
    try Self.validateMutablePath(url, matches: identity)
    if requiringNoCompanions { try Self.validateNoSQLiteCompanions(at: url) }
  }

  private func makeRevision(
    transactionID: String, number: Int, predecessorID: String?, draft: LedgerTransactionDraft,
    lifecycle: LedgerLifecycleState, createdAt: UTCInstant
  ) throws -> LedgerTransactionRevision {
    try .init(
      id: StableLedgerID.revision(transactionID: transactionID, revision: number),
      transactionID: transactionID, revision: number, predecessorID: predecessorID, draft: draft,
      lifecycle: lifecycle, createdAt: createdAt)
  }

  private static func validateReferences(
    _ revision: LedgerTransactionRevision, in snapshot: LedgerReadSnapshot,
    on database: OpaquePointer
  ) throws {
    guard
      revision.draft.effects.allSatisfy({ effect in
        snapshot.accounts.contains {
          $0.id == effect.accountID && $0.currencyUnit == effect.amount.unitCode
            && $0.lifecycle == .active
        }
      })
        && originMatches(revision.draft.origin, on: database)
        && categoryIsActive(revision.draft.categoryID, for: revision.draft.kind, on: database)
    else { throw Error.incompatibleCanonicalStore }
  }

  private static func originMatches(_ origin: LedgerOrigin, on database: OpaquePointer) -> Bool {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database, "SELECT label, provenance_id FROM main.ledger_origin WHERE origin_id=?", -1,
        &statement, nil
      ) == SQLITE_OK, let statement,
      bind(.text(origin.id), to: statement, at: 1), sqlite3_step(statement) == SQLITE_ROW
    else {
      if statement != nil { sqlite3_finalize(statement) }
      return false
    }
    defer { sqlite3_finalize(statement) }
    return text(statement, column: 0) == origin.label
      && optionalText(statement, column: 1) == origin.provenanceID
  }

  private static func categoryIsActive(
    _ categoryID: String?, for kind: LedgerTransactionKind, on database: OpaquePointer
  ) -> Bool {
    guard let categoryID else { return true }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database, "SELECT lifecycle, kind FROM main.ledger_category WHERE category_id=?", -1,
        &statement, nil
      ) == SQLITE_OK, let statement,
      bind(.text(categoryID), to: statement, at: 1), sqlite3_step(statement) == SQLITE_ROW
    else {
      if statement != nil { sqlite3_finalize(statement) }
      return false
    }
    defer { sqlite3_finalize(statement) }
    return text(statement, column: 0) == LedgerLifecycleState.active.rawValue
      && text(statement, column: 1).flatMap(LedgerCategoryKind.init(rawValue:))?.accepts(kind)
        == true
  }

  private static func predecessor(
    transactionID: String, revisionID: String, in snapshot: LedgerReadSnapshot
  ) throws -> LedgerTransactionRevision {
    guard let revision = snapshot.revisionHistory.first(where: { $0.id == revisionID }),
      revision.transactionID == transactionID
    else { throw Error.incompatibleCanonicalStore }
    return revision
  }

  package static func insert(
    _ revision: LedgerTransactionRevision, on database: OpaquePointer,
    includingSourceLiterals: Bool = true
  ) throws {
    let temporal = revision.draft.occurredAt
    let local = temporal.localDateTime
    let zone: (String, String)
    if let identifier = temporal.timeZone.ianaIdentifier {
      zone = ("iana", identifier)
    } else if let offset = temporal.timeZone.fixedOffsetSeconds {
      zone = ("fixed", String(offset))
    } else {
      throw Error.incompatibleCanonicalStore
    }
    try run(
      """
      INSERT INTO main.ledger_transaction_revision(
        revision_id, transaction_id, revision, predecessor_id, category_id, kind,
        instant_milliseconds, local_year, local_month, local_day, local_hour, local_minute,
        local_second, local_millisecond, timezone_kind, timezone_value, temporal_precision,
        resolved_offset_seconds, note, rounding_policy, origin_id, lifecycle, created_at_milliseconds
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      values: [
        .text(revision.id), .text(revision.transactionID), .int(revision.revision),
        .optionalText(revision.predecessorID), .optionalText(revision.draft.categoryID),
        .text(revision.draft.kind.rawValue), .int64(temporal.instant.epochMilliseconds),
        .int(local.date.year), .int(local.date.month), .int(local.date.day), .int(local.hour),
        .int(local.minute), .int(local.second), .int(local.millisecond), .text(zone.0),
        .text(zone.1), .text(temporal.precision.rawValue), .int(temporal.resolvedOffsetSeconds),
        .optionalText(revision.draft.note), .optionalText(revision.draft.roundingPolicy?.rawValue),
        .text(revision.draft.origin.id), .text(revision.lifecycle.rawValue),
        .int64(revision.createdAt.epochMilliseconds),
      ], on: database)
    for effect in revision.draft.effects {
      try run(
        "INSERT INTO main.ledger_transaction_effect(revision_id, account_id, direction, amount_literal, currency_unit) VALUES (?, ?, ?, ?, ?)",
        values: [
          .text(revision.id), .text(effect.accountID), .text(effect.direction.rawValue),
          .text(effect.amount.amount.rawLiteral), .text(effect.amount.unitCode),
        ], on: database)
    }
    for (ordinal, literal) in revision.draft.sourceLiterals.enumerated()
    where includingSourceLiterals {
      try run(
        "INSERT INTO main.ledger_transaction_source_literal(revision_id, ordinal, field, literal, provenance_id) VALUES (?, ?, ?, ?, ?)",
        values: [
          .text(revision.id), .int(ordinal), .text(literal.field), .text(literal.literal),
          .optionalText(literal.provenanceID),
        ], on: database)
    }
  }

  private static func validateCanonicalSchema(on database: OpaquePointer) throws {
    guard
      scalarInt("PRAGMA application_id", on: database) == Int(CanonicalLedgerSchema.applicationID),
      scalarText("SELECT value FROM ledger_meta WHERE key='schema_version'", on: database)
        == String(CanonicalLedgerSchema.version),
      scalarText("SELECT value FROM ledger_meta WHERE key='ledger_identity'", on: database)
        == "ledger-atlas-canonical",
      scalarText("SELECT value FROM ledger_meta WHERE key='schema_fingerprint'", on: database)
        == CanonicalLedgerSchema.fingerprint,
      schemaObjects(on: database) == CanonicalLedgerSchema.expectedObjects,
      scalarText("PRAGMA quick_check", on: database) == "ok",
      hasNoRows("PRAGMA foreign_key_check", on: database)
    else { throw Error.incompatibleCanonicalStore }
  }

  private static func schemaObjects(on database: OpaquePointer) -> [CanonicalSchemaObject]? {
    let sql =
      "SELECT type, name, tbl_name, sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      return nil
    }
    defer { sqlite3_finalize(statement) }
    var objects: [CanonicalSchemaObject] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let type = text(statement, column: 0),
        let name = text(statement, column: 1),
        let tableName = text(statement, column: 2),
        let ddl = text(statement, column: 3)
      else { return nil }
      objects.append(
        .init(
          type: type, name: name, tableName: tableName,
          ddl: CanonicalLedgerSchema.normalizedDDL(ddl)))
    }
    return objects.sorted { ($0.type, $0.name) < ($1.type, $1.name) }
  }

  private static func scalarInt(_ sql: String, on database: OpaquePointer) -> Int? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      return nil
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private static func scalarText(_ sql: String, on database: OpaquePointer) -> String? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      return nil
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return text(statement, column: 0)
  }

  private static func text(_ statement: OpaquePointer, column: Int32) -> String? {
    guard let value = sqlite3_column_text(statement, column) else { return nil }
    let byteCount = sqlite3_column_bytes(statement, column)
    guard byteCount >= 0 else { return nil }
    let data = Data(bytes: value, count: Int(byteCount))
    guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return nil }
    return text
  }

  private static func optionalText(_ statement: OpaquePointer, column: Int32) -> String? {
    sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : text(statement, column: column)
  }

  private static func hasNoRows(_ sql: String, on database: OpaquePointer) -> Bool {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      return false
    }
    defer { sqlite3_finalize(statement) }
    return sqlite3_step(statement) == SQLITE_DONE
  }

  private static func execute(_ sql: String, on database: OpaquePointer) throws {
    let result = sqlite3_exec(database, sql, nil, nil, nil)
    guard result == SQLITE_OK else { throw Error.sqliteFailure(code: result) }
  }

  private enum SQLValue {
    case text(String)
    case optionalText(String?)
    case int(Int)
    case optionalInt(Int?)
    case int64(Int64)
    case blob(Data)
  }

  private static func run(_ sql: String, values: [SQLValue], on database: OpaquePointer) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw Error.incompatibleCanonicalStore
    }
    defer { sqlite3_finalize(statement) }
    for (offset, value) in values.enumerated() {
      guard bind(value, to: statement, at: Int32(offset + 1)) else {
        throw Error.incompatibleCanonicalStore
      }
    }
    guard sqlite3_step(statement) == SQLITE_DONE else { throw Error.incompatibleCanonicalStore }
  }

  private static func bind(_ value: SQLValue, to statement: OpaquePointer, at index: Int32) -> Bool
  {
    switch value {
    case .text(let text):
      return text.withCString {
        sqlite3_bind_text(
          statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
          == SQLITE_OK
      }
    case .optionalText(let value):
      guard let value else { return sqlite3_bind_null(statement, index) == SQLITE_OK }
      return bind(.text(value), to: statement, at: index)
    case .int(let value): return sqlite3_bind_int64(statement, index, Int64(value)) == SQLITE_OK
    case .optionalInt(let value):
      guard let value else { return sqlite3_bind_null(statement, index) == SQLITE_OK }
      return bind(.int(value), to: statement, at: index)
    case .int64(let value): return sqlite3_bind_int64(statement, index, value) == SQLITE_OK
    case .blob(let data):
      return data.withUnsafeBytes {
        sqlite3_bind_blob64(
          statement, index, $0.baseAddress ?? UnsafeRawPointer(bitPattern: 1), UInt64(data.count),
          unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK
      }
    }
  }

  private static func openRecoveryJournal(at url: URL) throws -> Int32? {
    for suffix in ["-wal", "-shm"] {
      var companion = stat()
      errno = 0
      guard lstat(url.path + suffix, &companion) != 0, errno == ENOENT else {
        throw Error.incompatibleCanonicalStore
      }
    }
    let path = url.path + "-journal"
    let descriptor = Darwin.open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    if descriptor < 0 {
      guard errno == ENOENT else { throw Error.incompatibleCanonicalStore }
      return nil
    }
    var identity = stat()
    var atPath = stat()
    guard fstat(descriptor, &identity) == 0, lstat(path, &atPath) == 0,
      sameFile(identity, atPath), (identity.st_mode & S_IFMT) == S_IFREG,
      identity.st_uid == getuid(), identity.st_nlink == 1,
      (identity.st_mode & mode_t(0o777)) == mode_t(S_IRUSR | S_IWUSR)
    else {
      Darwin.close(descriptor)
      throw Error.incompatibleCanonicalStore
    }
    if identity.st_size == 0 {
      let bindingPath = path + ".ledger-atlas-binding"
      var binding = stat()
      guard lstat(bindingPath, &binding) == 0, isSafeJournalBinding(binding) else {
        Darwin.close(descriptor)
        throw Error.incompatibleCanonicalStore
      }
      Darwin.close(descriptor)
      return nil
    }
    guard identity.st_size >= 512, identity.st_size <= 1_073_741_824 else {
      Darwin.close(descriptor)
      throw Error.incompatibleCanonicalStore
    }
    return descriptor
  }

  private static func validateNoSQLiteCompanions(at url: URL) throws {
    for suffix in ["-wal", "-shm"] {
      var companion = stat()
      errno = 0
      guard lstat(url.path + suffix, &companion) != 0, errno == ENOENT else {
        throw Error.incompatibleCanonicalStore
      }
    }
    let journalPath = url.path + "-journal"
    var journal = stat()
    if lstat(journalPath, &journal) == 0 {
      guard journal.st_size == 0, isSafeJournalFile(journal) else {
        throw Error.incompatibleCanonicalStore
      }
      var binding = stat()
      guard lstat(journalPath + ".ledger-atlas-binding", &binding) == 0,
        isSafeJournalBinding(binding)
      else {
        throw Error.incompatibleCanonicalStore
      }
    } else {
      guard errno == ENOENT else { throw Error.incompatibleCanonicalStore }
    }
  }

  package static func validateInactiveSQLiteCompanions(
    at url: URL, databaseDescriptor: Int32
  ) throws {
    var database = stat()
    guard fstat(databaseDescriptor, &database) == 0, isSafeCanonicalFile(database) else {
      throw Error.incompatibleCanonicalStore
    }
    for suffix in ["-wal", "-shm"] {
      var companion = stat()
      errno = 0
      guard lstat(url.path + suffix, &companion) != 0, errno == ENOENT else {
        throw Error.incompatibleCanonicalStore
      }
    }
    let journalPath = url.path + "-journal"
    let journalDescriptor = Darwin.open(journalPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    if journalDescriptor < 0 {
      guard errno == ENOENT else { throw Error.incompatibleCanonicalStore }
      var binding = stat()
      errno = 0
      guard lstat(journalPath + ".ledger-atlas-binding", &binding) != 0, errno == ENOENT else {
        throw Error.incompatibleCanonicalStore
      }
      return
    }
    defer { Darwin.close(journalDescriptor) }
    var journal = stat()
    var journalAtPath = stat()
    guard fstat(journalDescriptor, &journal) == 0, lstat(journalPath, &journalAtPath) == 0,
      sameFile(journal, journalAtPath), journal.st_size == 0, isSafeJournalFile(journal)
    else { throw Error.incompatibleCanonicalStore }

    let bindingPath = journalPath + ".ledger-atlas-binding"
    let bindingDescriptor = Darwin.open(bindingPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard bindingDescriptor >= 0 else { throw Error.incompatibleCanonicalStore }
    defer { Darwin.close(bindingDescriptor) }
    var binding = stat()
    var bindingAtPath = stat()
    guard fstat(bindingDescriptor, &binding) == 0, lstat(bindingPath, &bindingAtPath) == 0,
      sameFile(binding, bindingAtPath), isSafeJournalBinding(binding)
    else { throw Error.incompatibleCanonicalStore }
    let expected = Data(journalBindingPayload(database: database, journal: journal).utf8)
    guard binding.st_size == expected.count else { throw Error.incompatibleCanonicalStore }
    var actual = Data(count: Int(binding.st_size))
    let count = actual.withUnsafeMutableBytes { bytes in
      pread(bindingDescriptor, bytes.baseAddress, bytes.count, 0)
    }
    guard count == actual.count, actual == expected else { throw Error.incompatibleCanonicalStore }
    var retainedJournal = stat()
    var retainedJournalAtPath = stat()
    var retainedBinding = stat()
    var retainedBindingAtPath = stat()
    guard
      fstat(journalDescriptor, &retainedJournal) == 0,
      lstat(journalPath, &retainedJournalAtPath) == 0,
      sameFile(journal, retainedJournal), sameFile(journal, retainedJournalAtPath),
      fstat(bindingDescriptor, &retainedBinding) == 0,
      lstat(bindingPath, &retainedBindingAtPath) == 0,
      sameFile(binding, retainedBinding), sameFile(binding, retainedBindingAtPath)
    else { throw Error.incompatibleCanonicalStore }
    for suffix in ["-wal", "-shm"] {
      var companion = stat()
      errno = 0
      guard lstat(url.path + suffix, &companion) != 0, errno == ENOENT else {
        throw Error.incompatibleCanonicalStore
      }
    }
  }

  private static func journalBindingPayload(database: stat, journal: stat) -> String {
    """
    ledger-atlas-journal-v3
    \(UInt64(bitPattern: Int64(database.st_dev)))
    \(database.st_ino)
    \(database.st_birthtimespec.tv_sec)
    \(database.st_birthtimespec.tv_nsec)
    \(UInt64(bitPattern: Int64(journal.st_dev)))
    \(journal.st_ino)
    \(journal.st_birthtimespec.tv_sec)
    \(journal.st_birthtimespec.tv_nsec)

    """
  }

  private static func isSafeJournalFile(_ value: stat) -> Bool {
    (value.st_mode & S_IFMT) == S_IFREG && value.st_uid == getuid() && value.st_nlink == 1
      && (value.st_mode & mode_t(0o777)) == mode_t(S_IRUSR | S_IWUSR)
  }

  private static func isSafeJournalBinding(_ value: stat) -> Bool {
    isSafeJournalFile(value) && value.st_size > 0 && value.st_size <= 256
  }

  private static func validatePath(_ url: URL, matches expected: stat) throws {
    var atPath = stat()
    guard lstat(url.path, &atPath) == 0, sameFile(expected, atPath) else {
      throw Error.incompatibleCanonicalStore
    }
  }

  private static func validateMutablePath(_ url: URL, matches expected: stat) throws {
    var atPath = stat()
    guard lstat(url.path, &atPath) == 0, sameInode(expected, atPath),
      (atPath.st_mode & S_IFMT) == S_IFREG, atPath.st_uid == getuid(), atPath.st_nlink == 1,
      (atPath.st_mode & mode_t(0o777)) == mode_t(S_IRUSR | S_IWUSR)
    else { throw Error.incompatibleCanonicalStore }
  }

  private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
      && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
      && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
      && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
      && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
  }

  private static func sameInode(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
  }

  private static func isSafeCanonicalFile(_ value: stat) -> Bool {
    (value.st_mode & S_IFMT) == S_IFREG && value.st_uid == getuid() && value.st_nlink == 1
      && (value.st_mode & mode_t(0o777)) == mode_t(S_IRUSR | S_IWUSR)
  }

  private static func openReadOnlyDatabase(_ descriptor: Int32) throws -> OpaquePointer {
    let sqliteDescriptor = dup(descriptor)
    guard sqliteDescriptor >= 0 else { throw Error.incompatibleCanonicalStore }
    defer { Darwin.close(sqliteDescriptor) }
    var database: OpaquePointer?
    let uri = "file:/dev/fd/\(sqliteDescriptor)?mode=ro"
    guard
      sqlite3_open_v2(
        uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX, nil)
        == SQLITE_OK,
      let database, sqlite3_db_readonly(database, "main") == 1
    else {
      if database != nil { sqlite3_close(database) }
      throw Error.incompatibleCanonicalStore
    }
    return database
  }

  private static func validateCanonicalJournalMode(on database: OpaquePointer) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA journal_mode", -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw Error.incompatibleCanonicalStore }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
      text(statement, column: 0)?.lowercased() == "delete"
    else { throw Error.incompatibleCanonicalStore }
  }
}

// MARK: - Tags, transaction templates and memos (schema v12)

extension LedgerStore {
  /// Adds a tag. Retrying with the same tag is a no-op; a different tag under the same ID fails.
  public func createTag(_ tag: LedgerTag) throws {
    _ = try mutate { _ in
      let tags = try Self.loadTags(on: database)
      if let existing = tags.first(where: { $0.id == tag.id }) {
        guard existing == tag else { throw Error.incompatibleCanonicalStore }
        return try Self.placeholderResult(origin: tag.origin, status: .unchanged)
      }
      guard tag.lifecycle == .active else { throw Error.incompatibleCanonicalStore }
      try Self.ensureUniqueActiveTagNames(tags + [tag])
      try Self.ensureOrigin(tag.origin, on: database)
      try Self.run(
        "INSERT INTO main.ledger_tag(tag_id, name, origin_id, lifecycle) VALUES (?, ?, ?, ?)",
        values: [
          .text(tag.id), .text(tag.name), .text(tag.origin.id), .text(tag.lifecycle.rawValue),
        ], on: database)
      return try Self.placeholderResult(origin: tag.origin)
    }
  }

  /// Renames or tombstones a tag. Its ID, origin and every stored link stay as they are, so
  /// history shows the new name and a tombstoned tag still labels the revisions it was on.
  public func updateTag(_ tag: LedgerTag) throws {
    _ = try mutate { _ in
      let tags = try Self.loadTags(on: database)
      guard let existing = tags.first(where: { $0.id == tag.id }), existing.origin == tag.origin
      else { throw Error.incompatibleCanonicalStore }
      if existing == tag {
        return try Self.placeholderResult(origin: tag.origin, status: .unchanged)
      }
      guard existing.lifecycle == .active else { throw Error.incompatibleCanonicalStore }
      try Self.ensureUniqueActiveTagNames(tags.map { $0.id == tag.id ? tag : $0 })
      try Self.run(
        "UPDATE main.ledger_tag SET name=?, lifecycle=? WHERE tag_id=?",
        values: [.text(tag.name), .text(tag.lifecycle.rawValue), .text(tag.id)], on: database)
      return try Self.placeholderResult(origin: tag.origin)
    }
  }

  /// Creates or edits a template. Editing changes future drafts only; a tombstoned template
  /// cannot change again.
  public func saveTransactionTemplate(_ template: LedgerTransactionTemplate) throws {
    _ = try mutate { snapshot in
      let existing = try Self.loadTransactionTemplates(on: database)
        .first(where: { $0.id == template.id })
      if let existing {
        if existing == template {
          return try Self.placeholderResult(origin: template.origin, status: .unchanged)
        }
        guard existing.origin == template.origin, existing.lifecycle == .active else {
          throw Error.incompatibleCanonicalStore
        }
      } else {
        guard template.lifecycle == .active else { throw Error.incompatibleCanonicalStore }
      }
      try Self.validateTemplateReferences(template, previous: existing, in: snapshot, on: database)
      try Self.ensureOrigin(template.origin, on: database)
      try Self.run(
        """
        INSERT INTO main.ledger_transaction_template(
          template_id, name, kind, category_id, amount_literal, currency_unit, note, account_id,
          counter_account_id, origin_id, lifecycle
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(template_id) DO UPDATE SET
          name=excluded.name, kind=excluded.kind, category_id=excluded.category_id,
          amount_literal=excluded.amount_literal, currency_unit=excluded.currency_unit,
          note=excluded.note, account_id=excluded.account_id,
          counter_account_id=excluded.counter_account_id, lifecycle=excluded.lifecycle
        """,
        values: [
          .text(template.id), .text(template.name), .text(template.kind.rawValue),
          .optionalText(template.categoryID), .text(template.amount.amount.rawLiteral),
          .text(template.amount.unitCode), .optionalText(template.note),
          .text(template.accountID), .optionalText(template.counterAccountID),
          .text(template.origin.id), .text(template.lifecycle.rawValue),
        ], on: database)
      try Self.run(
        "DELETE FROM main.ledger_template_tag WHERE template_id=?",
        values: [.text(template.id)], on: database)
      for tagID in template.tags.tagIDs {
        try Self.run(
          "INSERT INTO main.ledger_template_tag(template_id, tag_id) VALUES (?, ?)",
          values: [.text(template.id), .text(tagID)], on: database)
      }
      return try Self.placeholderResult(origin: template.origin)
    }
  }

  /// Creates, edits or tombstones a dated memo. Memos never touch balances.
  public func saveMemo(_ memo: LedgerMemo) throws {
    _ = try mutate { _ in
      if let existing = try Self.loadMemos(on: database).first(where: { $0.id == memo.id }) {
        if existing == memo {
          return try Self.placeholderResult(origin: memo.origin, status: .unchanged)
        }
        guard existing.origin == memo.origin, existing.lifecycle == .active else {
          throw Error.incompatibleCanonicalStore
        }
      } else {
        guard memo.lifecycle == .active else { throw Error.incompatibleCanonicalStore }
      }
      try Self.ensureOrigin(memo.origin, on: database)
      try Self.run(
        """
        INSERT INTO main.ledger_memo(
          memo_id, body, local_year, local_month, local_day, origin_id, lifecycle
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(memo_id) DO UPDATE SET
          body=excluded.body, local_year=excluded.local_year,
          local_month=excluded.local_month, local_day=excluded.local_day,
          lifecycle=excluded.lifecycle
        """,
        values: [
          .text(memo.id), .text(memo.body), .int(memo.date.year), .int(memo.date.month),
          .int(memo.date.day), .text(memo.origin.id), .text(memo.lifecycle.rawValue),
        ], on: database)
      return try Self.placeholderResult(origin: memo.origin)
    }
  }

  /// Restores annotations from a portable package into an empty ledger. Rows are written as
  /// stored, including tombstoned tags that history still points at; foreign keys and the
  /// post-write health check reject dangling links.
  fileprivate static func writeImportedAnnotations(
    _ package: LedgerCanonicalPackage, on database: OpaquePointer
  ) throws {
    for tag in package.tags {
      try ensureOrigin(tag.origin, on: database)
      try run(
        "INSERT INTO main.ledger_tag(tag_id, name, origin_id, lifecycle) VALUES (?, ?, ?, ?)",
        values: [
          .text(tag.id), .text(tag.name), .text(tag.origin.id), .text(tag.lifecycle.rawValue),
        ], on: database)
    }
    for (revisionID, links) in package.revisionTags {
      for tagID in links.tagIDs {
        try run(
          "INSERT INTO main.ledger_revision_tag(revision_id, tag_id) VALUES (?, ?)",
          values: [.text(revisionID), .text(tagID)], on: database)
      }
    }
    for template in package.transactionTemplates {
      try ensureOrigin(template.origin, on: database)
      try run(
        """
        INSERT INTO main.ledger_transaction_template(
          template_id, name, kind, category_id, amount_literal, currency_unit, note, account_id,
          counter_account_id, origin_id, lifecycle
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        values: [
          .text(template.id), .text(template.name), .text(template.kind.rawValue),
          .optionalText(template.categoryID), .text(template.amount.amount.rawLiteral),
          .text(template.amount.unitCode), .optionalText(template.note),
          .text(template.accountID), .optionalText(template.counterAccountID),
          .text(template.origin.id), .text(template.lifecycle.rawValue),
        ], on: database)
      for tagID in template.tags.tagIDs {
        try run(
          "INSERT INTO main.ledger_template_tag(template_id, tag_id) VALUES (?, ?)",
          values: [.text(template.id), .text(tagID)], on: database)
      }
    }
    for memo in package.memos {
      try ensureOrigin(memo.origin, on: database)
      try run(
        """
        INSERT INTO main.ledger_memo(
          memo_id, body, local_year, local_month, local_day, origin_id, lifecycle
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        values: [
          .text(memo.id), .text(memo.body), .int(memo.date.year), .int(memo.date.month),
          .int(memo.date.day), .text(memo.origin.id), .text(memo.lifecycle.rawValue),
        ], on: database)
    }
  }

  private static func ensureUniqueActiveTagNames(_ tags: [LedgerTag]) throws {
    do {
      try LedgerTag.validateActiveNamesAreUnique(tags)
    } catch {
      throw Error.duplicateTagName
    }
  }

  private static func tagsByID(on database: OpaquePointer) throws -> [String: LedgerTag] {
    Dictionary(uniqueKeysWithValues: try loadTags(on: database).map { ($0.id, $0) })
  }

  /// Writes a new revision's links. Links it shares with `previous` may point at tombstoned
  /// tags; any other link must point at an active tag.
  private static func writeRevisionTags(
    _ tags: LedgerTagLinks, revisionID: String, previous: LedgerTagLinks,
    on database: OpaquePointer
  ) throws {
    guard !tags.isEmpty else { return }
    try tags.validateNewLinks(previous: previous, tags: tagsByID(on: database))
    for tagID in tags.tagIDs {
      try run(
        "INSERT INTO main.ledger_revision_tag(revision_id, tag_id) VALUES (?, ?)",
        values: [.text(revisionID), .text(tagID)], on: database)
    }
  }

  private static func validateTemplateReferences(
    _ template: LedgerTransactionTemplate, previous: LedgerTransactionTemplate?,
    in snapshot: LedgerReadSnapshot, on database: OpaquePointer
  ) throws {
    let accounts = Dictionary(uniqueKeysWithValues: snapshot.accounts.map { ($0.id, $0) })
    for accountID in [template.accountID] + (template.counterAccountID.map { [$0] } ?? []) {
      guard let account = accounts[accountID], account.lifecycle == .active,
        account.currencyUnit == template.amount.unitCode
      else { throw Error.incompatibleCanonicalStore }
    }
    guard categoryIsActive(template.categoryID, for: template.kind, on: database) else {
      throw Error.incompatibleCanonicalStore
    }
    try template.tags.validateNewLinks(
      previous: previous?.tags ?? .empty, tags: tagsByID(on: database))
  }

  fileprivate static func loadTags(on database: OpaquePointer) throws -> [LedgerTag] {
    let tags = try load(
      sql:
        "SELECT t.tag_id, t.name, t.lifecycle, o.origin_id, o.label, o.provenance_id FROM main.ledger_tag t JOIN main.ledger_origin o ON o.origin_id=t.origin_id ORDER BY t.tag_id",
      on: database
    ) { row in
      try LedgerTag(
        id: row[0], name: row[1],
        origin: LedgerOrigin(
          id: row[3], label: row[4], provenanceID: row[5].isEmpty ? nil : row[5]),
        lifecycle: try requireRaw(LedgerLifecycleState.self, row[2]))
    }
    try LedgerTag.validateActiveNamesAreUnique(tags)
    return tags
  }

  fileprivate static func loadRevisionTags(on database: OpaquePointer) throws
    -> [String: LedgerTagLinks]
  {
    let pairs = try load(
      sql: "SELECT revision_id, tag_id FROM main.ledger_revision_tag ORDER BY revision_id, tag_id",
      on: database
    ) { row in (row[0], row[1]) }
    return try Dictionary(grouping: pairs, by: { $0.0 }).mapValues {
      try LedgerTagLinks($0.map { $0.1 })
    }
  }

  fileprivate static func loadTransactionTemplates(on database: OpaquePointer) throws
    -> [LedgerTransactionTemplate]
  {
    let pairs = try load(
      sql: "SELECT template_id, tag_id FROM main.ledger_template_tag ORDER BY template_id, tag_id",
      on: database
    ) { row in (row[0], row[1]) }
    let links = try Dictionary(grouping: pairs, by: { $0.0 }).mapValues {
      try LedgerTagLinks($0.map { $0.1 })
    }
    return try load(
      sql:
        "SELECT t.template_id, t.name, t.kind, t.category_id, t.amount_literal, t.currency_unit, t.note, t.account_id, t.counter_account_id, t.lifecycle, o.origin_id, o.label, o.provenance_id FROM main.ledger_transaction_template t JOIN main.ledger_origin o ON o.origin_id=t.origin_id ORDER BY t.template_id",
      on: database
    ) { row in
      try LedgerTransactionTemplate(
        id: row[0], name: row[1], kind: try requireRaw(LedgerTransactionKind.self, row[2]),
        categoryID: row[3].isEmpty ? nil : row[3],
        amount: CurrencyAmount(unitCode: row[5], amount: ExactDecimal(row[4])),
        note: row[6].isEmpty ? nil : row[6], accountID: row[7],
        counterAccountID: row[8].isEmpty ? nil : row[8], tags: links[row[0]] ?? .empty,
        origin: LedgerOrigin(
          id: row[10], label: row[11], provenanceID: row[12].isEmpty ? nil : row[12]),
        lifecycle: try requireRaw(LedgerLifecycleState.self, row[9]))
    }
  }

  fileprivate static func loadMemos(on database: OpaquePointer) throws -> [LedgerMemo] {
    try load(
      sql:
        "SELECT m.memo_id, m.body, m.local_year, m.local_month, m.local_day, m.lifecycle, o.origin_id, o.label, o.provenance_id FROM main.ledger_memo m JOIN main.ledger_origin o ON o.origin_id=m.origin_id ORDER BY m.memo_id",
      on: database
    ) { row in
      try LedgerMemo(
        id: row[0], body: row[1],
        date: SourceLocalDate(
          year: try requireInt(row[2]), month: try requireInt(row[3]),
          day: try requireInt(row[4])),
        origin: LedgerOrigin(
          id: row[6], label: row[7], provenanceID: row[8].isEmpty ? nil : row[8]),
        lifecycle: try requireRaw(LedgerLifecycleState.self, row[5]))
    }
  }
}

// MARK: - XLSX import (LA-040)

extension LedgerStore {
  /// Applies an XLSX import plan in one database transaction: every record and transaction
  /// is added, or nothing is.
  ///
  /// Import only adds. The plan must have no conflicts, and none of its new records may have
  /// appeared since it was made. Records are created active so new transactions can point at
  /// them; records the workbook marks deleted are closed at the end, inside the same
  /// transaction, and the usual health check runs on the result before it commits.
  public func applyXLSXImport(_ plan: LedgerXLSXImportPlan, createdAt: UTCInstant) throws {
    guard plan.canApply else { throw Error.importPlanNotApplicable }
    guard !plan.isEmpty else { return }
    let requests = plan.transactions.map {
      CreateTransactionRequest(
        idempotencyKey: $0.idempotencyKey, draft: $0.draft, createdAt: createdAt, tags: $0.tags)
    }
    let revisions = try requests.map { try preparedRevision(for: $0) }
    _ = try mutate { start in
      try Self.ensureImportIsNew(plan, revisions: revisions, in: start)
      let active = LedgerLifecycleState.active.rawValue
      for group in plan.accountGroups {
        try Self.run(
          "INSERT INTO main.ledger_account_group(group_id, name, display_order, lifecycle) VALUES (?, ?, ?, ?)",
          values: [.text(group.id), .text(group.name), .int(group.displayOrder), .text(active)],
          on: database)
      }
      for account in plan.accounts {
        try Self.ensureOrigin(account.origin, on: database)
        try Self.run(
          "INSERT INTO main.ledger_account(account_id, name, currency_unit, origin_id, lifecycle) VALUES (?, ?, ?, ?, ?)",
          values: [
            .text(account.id), .text(account.name), .text(account.currencyUnit),
            .text(account.origin.id), .text(active),
          ], on: database)
        try Self.writeAccountPreferences(account, on: database)
      }
      for category in plan.categories {
        try Self.ensureOrigin(category.origin, on: database)
        try Self.run(
          "INSERT INTO main.ledger_category(category_id, name, kind, origin_id, lifecycle) VALUES (?, ?, ?, ?, ?)",
          values: [
            .text(category.id), .text(category.name), .text(category.kind.rawValue),
            .text(category.origin.id), .text(active),
          ], on: database)
        try Self.writeCategoryTree(category, on: database)
      }
      for tag in plan.tags {
        try Self.ensureOrigin(tag.origin, on: database)
        try Self.run(
          "INSERT INTO main.ledger_tag(tag_id, name, origin_id, lifecycle) VALUES (?, ?, ?, ?)",
          values: [.text(tag.id), .text(tag.name), .text(tag.origin.id), .text(active)],
          on: database)
      }

      // Transactions see the records above through a fresh read, and go through the same
      // checks as any new transaction.
      let withRecords = try CanonicalLedgerHealth.readSnapshot(database)
      var last = try Self.placeholderResult(origin: try LedgerXLSXImportPlan.origin())
      for (revision, request) in zip(revisions, requests) {
        last = try Self.insertNew(revision, tags: request.tags, in: withRecords, on: database)
        try mutationTestHook?(.afterInsertingTransaction)
      }

      // Close what the workbook marks deleted, children before parents.
      let tombstoned = LedgerLifecycleState.tombstoned.rawValue
      for tag in plan.tags where tag.lifecycle == .tombstoned {
        try Self.run(
          "UPDATE main.ledger_tag SET lifecycle=? WHERE tag_id=?",
          values: [.text(tombstoned), .text(tag.id)], on: database)
      }
      for category in plan.categories.reversed() where category.lifecycle == .tombstoned {
        try Self.run(
          "UPDATE main.ledger_category SET lifecycle=? WHERE category_id=?",
          values: [.text(tombstoned), .text(category.id)], on: database)
      }
      for account in plan.accounts where account.lifecycle == .tombstoned {
        try Self.run(
          "UPDATE main.ledger_account SET lifecycle=? WHERE account_id=?",
          values: [.text(tombstoned), .text(account.id)], on: database)
      }
      for group in plan.accountGroups where group.lifecycle == .tombstoned {
        try Self.run(
          "UPDATE main.ledger_account_group SET lifecycle=? WHERE group_id=?",
          values: [.text(tombstoned), .text(group.id)], on: database)
      }
      try Self.ensureImportedRecordRules(plan, in: CanonicalLedgerHealth.readSnapshot(database))
      return last
    }
  }

  /// Refuses a plan made against an older state of the ledger.
  private static func ensureImportIsNew(
    _ plan: LedgerXLSXImportPlan, revisions: [LedgerTransactionRevision],
    in snapshot: LedgerReadSnapshot
  ) throws {
    let groups = Set(snapshot.accountGroups.map(\.id))
    let accounts = Set(snapshot.accounts.map(\.id))
    let categories = Set(snapshot.categories.map(\.id))
    let tags = Set(snapshot.tags.map(\.id))
    let transactions = Set(snapshot.transactions.map(\.id))
    guard plan.accountGroups.allSatisfy({ !groups.contains($0.id) }),
      plan.accounts.allSatisfy({ !accounts.contains($0.id) }),
      plan.categories.allSatisfy({ !categories.contains($0.id) }),
      plan.tags.allSatisfy({ !tags.contains($0.id) }),
      revisions.allSatisfy({ !transactions.contains($0.transactionID) })
    else { throw Error.importPlanNotApplicable }
  }

  /// The rules the app keeps when records are made one at a time, checked on the final
  /// state: an active account sits in an active group, an active category under an active,
  /// shown parent of the same kind with no loop, and active tag names stay unique.
  private static func ensureImportedRecordRules(
    _ plan: LedgerXLSXImportPlan, in snapshot: LedgerReadSnapshot
  ) throws {
    let groups = Dictionary(uniqueKeysWithValues: snapshot.accountGroups.map { ($0.id, $0) })
    for account in plan.accounts where account.lifecycle == .active {
      if let groupID = account.groupID, groups[groupID]?.lifecycle != .active {
        throw Error.importPlanNotApplicable
      }
    }
    let categories = Dictionary(uniqueKeysWithValues: snapshot.categories.map { ($0.id, $0) })
    for category in plan.categories {
      guard let parentID = category.parentID else { continue }
      guard let parent = categories[parentID], parent.kind == category.kind else {
        throw Error.importPlanNotApplicable
      }
      if category.lifecycle == .active, parent.lifecycle != .active || parent.hidden {
        throw Error.importPlanNotApplicable
      }
      var visited: Set<String> = []
      var cursor: String? = category.id
      while let id = cursor {
        guard visited.insert(id).inserted else { throw Error.categoryCycleDetected }
        cursor = categories[id]?.parentID
      }
    }
    try ensureUniqueActiveTagNames(snapshot.tags)
  }
}

// MARK: - Receipt attachments (schema v13, LA-041)

extension LedgerStore {
  /// Stores a receipt in the ledger. The media type comes from the bytes, never the caller.
  /// Adding the same image again from the same origin returns the stored receipt and, when
  /// `transactionID` is given, links it there.
  @discardableResult
  public func addReceipt(
    _ bytes: Data, origin: LedgerOrigin, linkedTo transactionID: String? = nil,
    createdAt: UTCInstant
  ) throws -> LedgerReceiptAttachment {
    guard !bytes.isEmpty, bytes.count <= LedgerReceiptAttachment.maximumBytes,
      let mediaType = LedgerReceiptAttachment.MediaType(sniffing: bytes)
    else { throw Error.unsupportedReceipt }
    let sha256 = LedgerReceiptAttachment.digest(bytes)
    let attachment = try LedgerReceiptAttachment(
      id: LedgerReceiptAttachment.id(origin: origin, sha256: sha256),
      transactionID: transactionID, sha256: sha256, byteCount: bytes.count,
      mediaType: mediaType, origin: origin, createdAt: createdAt)
    var stored = attachment
    _ = try mutate { _ in
      if let existing = try Self.loadReceiptAttachments(on: database).first(where: {
        $0.id == attachment.id
      }) {
        guard existing.lifecycle == .active else { throw Error.receiptRemoved }
        stored = existing
        guard let transactionID, existing.transactionID != transactionID else {
          return try Self.placeholderResult(origin: origin, status: .unchanged)
        }
        stored = try Self.relinkReceipt(existing, to: transactionID, on: database)
        return try Self.placeholderResult(origin: origin)
      }
      if let transactionID { try Self.ensureReceiptTarget(transactionID, on: database) }
      try Self.ensureOrigin(origin, on: database)
      try Self.run(
        """
        INSERT INTO main.ledger_receipt_attachment(
          attachment_id, transaction_id, sha256, byte_count, media_type, bytes, origin_id,
          created_at_milliseconds, lifecycle
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        values: [
          .text(attachment.id), .optionalText(transactionID), .text(sha256),
          .int(bytes.count), .text(mediaType.rawValue), .blob(bytes), .text(origin.id),
          .int64(createdAt.epochMilliseconds), .text(LedgerLifecycleState.active.rawValue),
        ], on: database)
      // The total budget is checked here, inside the same transaction as the insert, so two
      // adds cannot race past it.
      guard Self.receiptBytesTotal(on: database) <= LedgerReceiptAttachment.maximumTotalBytes
      else { throw Error.unsupportedReceipt }
      return try Self.placeholderResult(origin: origin)
    }
    return stored
  }

  /// Links a receipt to a transaction, or unlinks it with nil. The target may be a ledger
  /// transaction (deleted ones included), an imported event or an imported transfer.
  public func linkReceipt(_ attachmentID: String, to transactionID: String?) throws {
    _ = try mutate { _ in
      guard
        let existing = try Self.loadReceiptAttachments(on: database).first(where: {
          $0.id == attachmentID
        })
      else { throw Error.incompatibleCanonicalStore }
      guard existing.lifecycle == .active else { throw Error.receiptRemoved }
      if existing.transactionID == transactionID {
        return try Self.placeholderResult(origin: existing.origin, status: .unchanged)
      }
      _ = try Self.relinkReceipt(existing, to: transactionID, on: database)
      return try Self.placeholderResult(origin: existing.origin)
    }
  }

  /// Removes a receipt from view. Its bytes stay so a restore of this ledger is exact.
  public func tombstoneReceipt(_ attachmentID: String) throws {
    _ = try mutate { _ in
      guard
        let existing = try Self.loadReceiptAttachments(on: database).first(where: {
          $0.id == attachmentID
        })
      else { throw Error.incompatibleCanonicalStore }
      if existing.lifecycle == .tombstoned {
        return try Self.placeholderResult(origin: existing.origin, status: .unchanged)
      }
      try Self.run(
        "UPDATE main.ledger_receipt_attachment SET lifecycle=? WHERE attachment_id=?",
        values: [.text(LedgerLifecycleState.tombstoned.rawValue), .text(attachmentID)],
        on: database)
      return try Self.placeholderResult(origin: existing.origin)
    }
  }

  /// Every receipt's metadata, without the bytes.
  public func receiptAttachments() throws -> [LedgerReceiptAttachment] {
    try Self.loadReceiptAttachments(on: database)
  }

  /// One receipt's bytes, checked against its stored sha256.
  public func receiptBytes(_ attachmentID: String) throws -> Data {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT bytes, sha256 FROM main.ledger_receipt_attachment WHERE attachment_id=?", -1,
        &statement, nil) == SQLITE_OK, let statement
    else { throw Error.incompatibleCanonicalStore }
    defer { sqlite3_finalize(statement) }
    guard Self.bind(.text(attachmentID), to: statement, at: 1),
      sqlite3_step(statement) == SQLITE_ROW,
      sqlite3_column_type(statement, 0) == SQLITE_BLOB
    else { throw Error.incompatibleCanonicalStore }
    let count = Int(sqlite3_column_bytes(statement, 0))
    guard count > 0, let pointer = sqlite3_column_blob(statement, 0) else {
      throw Error.incompatibleCanonicalStore
    }
    let data = Data(bytes: pointer, count: count)
    guard LedgerReceiptAttachment.digest(data) == Self.text(statement, column: 1) else {
      throw Error.incompatibleCanonicalStore
    }
    return data
  }

  private static func relinkReceipt(
    _ existing: LedgerReceiptAttachment, to transactionID: String?, on database: OpaquePointer
  ) throws -> LedgerReceiptAttachment {
    if let transactionID { try ensureReceiptTarget(transactionID, on: database) }
    try run(
      "UPDATE main.ledger_receipt_attachment SET transaction_id=? WHERE attachment_id=?",
      values: [.optionalText(transactionID), .text(existing.id)], on: database)
    return try LedgerReceiptAttachment(
      id: existing.id, transactionID: transactionID, sha256: existing.sha256,
      byteCount: existing.byteCount, mediaType: existing.mediaType, origin: existing.origin,
      createdAt: existing.createdAt, lifecycle: existing.lifecycle)
  }

  private static func ensureReceiptTarget(_ transactionID: String, on database: OpaquePointer)
    throws
  {
    guard CanonicalIdentifier.isValid(transactionID) else {
      throw Error.incompatibleCanonicalStore
    }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        """
        SELECT 1 FROM main.ledger_transaction WHERE transaction_id=?1
        UNION ALL SELECT 1 FROM main.economic_event WHERE event_id=?1
        UNION ALL SELECT 1 FROM main.economic_event_transfer WHERE transfer_id=?1
        """, -1, &statement, nil) == SQLITE_OK, let statement
    else { throw Error.incompatibleCanonicalStore }
    defer { sqlite3_finalize(statement) }
    guard bind(.text(transactionID), to: statement, at: 1),
      sqlite3_step(statement) == SQLITE_ROW
    else { throw Error.incompatibleCanonicalStore }
  }

  private static func receiptBytesTotal(on database: OpaquePointer) -> Int {
    scalarInt(
      "SELECT coalesce(sum(length(bytes)), 0) FROM main.ledger_receipt_attachment",
      on: database) ?? Int.max
  }

  fileprivate static func loadReceiptAttachments(on database: OpaquePointer) throws
    -> [LedgerReceiptAttachment]
  {
    try load(
      sql:
        "SELECT r.attachment_id, r.transaction_id, r.sha256, r.byte_count, r.media_type, o.origin_id, o.label, o.provenance_id, r.created_at_milliseconds, r.lifecycle FROM main.ledger_receipt_attachment r JOIN main.ledger_origin o ON o.origin_id=r.origin_id ORDER BY r.created_at_milliseconds, r.attachment_id",
      on: database
    ) { row in
      guard let byteCount = Int(row[3]), let created = Int64(row[8]),
        let mediaType = LedgerReceiptAttachment.MediaType(rawValue: row[4])
      else { throw Error.incompatibleCanonicalStore }
      return try LedgerReceiptAttachment(
        id: row[0], transactionID: row[1].isEmpty ? nil : row[1], sha256: row[2],
        byteCount: byteCount, mediaType: mediaType,
        origin: LedgerOrigin(id: row[5], label: row[6], provenanceID: row[7].isEmpty ? nil : row[7]),
        createdAt: UTCInstant(epochMilliseconds: created),
        lifecycle: try requireRaw(LedgerLifecycleState.self, row[9]))
    }
  }
}

// MARK: - Portable package import graph (LA-048)

extension LedgerStore {
  /// More rows than any real ledger has. A package over this is refused before anything is
  /// written.
  static let maximumImportGraphRows = 2_000_000

  /// Rebuilds an imported ledger from a package. The graph rows go in first, verbatim, then
  /// the product rows, then materialization; health validation and the receipt signature check
  /// run before commit, and the whole ledger must hash to the checksum taken at export.
  fileprivate func applyImportedExport(
    _ package: LedgerCanonicalPackage, graph: LedgerImportGraph
  ) throws {
    guard graph.schemaVersion == CanonicalLedgerSchema.version,
      graph.schemaFingerprint == CanonicalLedgerSchema.fingerprint
    else { throw Error.importGraphSchemaMismatch }
    guard package.preservedSource.isEmpty,
      graph.tables.map(\.name) == LedgerImportGraph.tableNames,
      graph.tables.reduce(0, { $0 + $1.rows.count }) <= Self.maximumImportGraphRows,
      let identity = graph.trustIdentity
    else { throw Error.importGraphMismatch }
    guard let url, try LedgerReceiptTrust.key(for: url, create: false, stableIdentity: identity) != nil
    else { throw Error.importGraphKeyMissing }
    // Only a real mismatch (wrong tables or columns, a refused insert, a different checksum)
    // reports as tampered. A busy or full disk or a health failure surfaces as itself.
    try Self.validateProductRows(package, allowingImportProvenance: true)
    _ = try mutate(trustIdentity: identity) { snapshot in
      let tables = CanonicalLedgerSchema.expectedObjects
        .filter { $0.type == "table" && $0.name != "ledger_meta" }.map(\.name)
      guard try !Self.hasRows(in: tables, on: database) else {
        throw Error.incompatibleCanonicalStore
      }
      try Self.writeImportGraph(graph, phase: .beforeProductRows, on: database)
      try Self.writeProductRows(
        package, snapshot: snapshot, on: database, afterImportGraph: true)
      try Self.writeImportGraph(graph, phase: .afterProductRows, on: database)
      try Self.materializeImportedEvents(on: database)
      guard try Self.canonicalChecksum(database) == graph.canonicalChecksum else {
        throw Error.importGraphMismatch
      }
      return try Self.placeholderResult(origin: LedgerOrigin.imported())
    }
  }

  /// Reads every import-graph table in rowid order, so the first receipt stays first and keeps
  /// naming the ledger's receipt key. Runs inside the caller's read transaction.
  static func readImportGraph(on database: OpaquePointer) throws -> LedgerImportGraph {
    guard
      let version = scalarText(
        "SELECT value FROM main.ledger_meta WHERE key='schema_version'", on: database),
      let schemaVersion = Int(version),
      let fingerprint = scalarText(
        "SELECT value FROM main.ledger_meta WHERE key='schema_fingerprint'", on: database)
    else { throw Error.incompatibleCanonicalStore }
    var tables: [LedgerImportGraph.Table] = []
    for name in LedgerImportGraph.tableNames {
      let columns = try tableColumns(name, on: database)
      let quoted = columns.map { "\"\($0)\"" }.joined(separator: ", ")
      var statement: OpaquePointer?
      guard
        sqlite3_prepare_v2(
          database, "SELECT \(quoted) FROM main.\(name) ORDER BY rowid", -1, &statement, nil)
          == SQLITE_OK, let statement
      else { throw Error.incompatibleCanonicalStore }
      defer { sqlite3_finalize(statement) }
      var rows: [[LedgerImportGraph.Value]] = []
      while true {
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { break }
        guard step == SQLITE_ROW else { throw Error.incompatibleCanonicalStore }
        rows.append(try (0..<Int32(columns.count)).map { try graphValue(statement, column: $0) })
      }
      tables.append(.init(name: name, columns: columns, rows: rows))
    }
    return .init(
      schemaVersion: schemaVersion, schemaFingerprint: fingerprint,
      canonicalChecksum: try canonicalChecksum(database), tables: tables)
  }

  private enum ImportGraphPhase { case beforeProductRows, afterProductRows }

  private static func writeImportGraph(
    _ graph: LedgerImportGraph, phase: ImportGraphPhase, on database: OpaquePointer
  ) throws {
    for table in graph.tables
    where LedgerImportGraph.productLinkedTableNames.contains(table.name)
      == (phase == .afterProductRows)
    {
      // Column names come from this ledger's own schema, never from the package.
      guard LedgerImportGraph.tableNames.contains(table.name),
        try tableColumns(table.name, on: database) == table.columns
      else { throw Error.importGraphMismatch }
      let quoted = table.columns.map { "\"\($0)\"" }.joined(separator: ", ")
      let placeholders = Array(repeating: "?", count: table.columns.count).joined(separator: ", ")
      var statement: OpaquePointer?
      guard
        sqlite3_prepare_v2(
          database, "INSERT INTO main.\(table.name)(\(quoted)) VALUES (\(placeholders))", -1,
          &statement, nil) == SQLITE_OK, let statement
      else { throw Error.incompatibleCanonicalStore }
      defer { sqlite3_finalize(statement) }
      for row in table.rows {
        guard row.count == table.columns.count,
          sqlite3_reset(statement) == SQLITE_OK, sqlite3_clear_bindings(statement) == SQLITE_OK
        else { throw Error.importGraphMismatch }
        for (offset, value) in row.enumerated() {
          guard bindGraphValue(value, to: statement, at: Int32(offset + 1)) else {
            throw Error.importGraphMismatch
          }
        }
        let step = sqlite3_step(statement)
        guard step == SQLITE_DONE else {
          // A row the schema rejects is a mismatch; anything else (busy, full) is a failure.
          switch step & 0xff {
          case SQLITE_CONSTRAINT, SQLITE_MISMATCH, SQLITE_TOOBIG, SQLITE_RANGE:
            throw Error.importGraphMismatch
          default: throw Error.sqliteFailure(code: step)
          }
        }
      }
    }
  }

  private static func tableColumns(_ table: String, on database: OpaquePointer) throws -> [String] {
    let columns = try load(
      sql: "SELECT name FROM pragma_table_info('\(table)') ORDER BY cid", on: database,
      map: { $0[0] })
    guard !columns.isEmpty else { throw Error.incompatibleCanonicalStore }
    return columns
  }

  private static func graphValue(_ statement: OpaquePointer, column: Int32) throws
    -> LedgerImportGraph.Value
  {
    switch sqlite3_column_type(statement, column) {
    case SQLITE_NULL: return .null
    case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, column))
    case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, column))
    case SQLITE_TEXT:
      guard let text = text(statement, column: column) else {
        throw Error.incompatibleCanonicalStore
      }
      return .text(text)
    case SQLITE_BLOB:
      let count = Int(sqlite3_column_bytes(statement, column))
      guard count > 0 else { return .blob(Data()) }
      guard let bytes = sqlite3_column_blob(statement, column) else {
        throw Error.incompatibleCanonicalStore
      }
      return .blob(Data(bytes: bytes, count: count))
    default: throw Error.incompatibleCanonicalStore
    }
  }

  private static func bindGraphValue(
    _ value: LedgerImportGraph.Value, to statement: OpaquePointer, at index: Int32
  ) -> Bool {
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    switch value {
    case .null: return sqlite3_bind_null(statement, index) == SQLITE_OK
    case .integer(let value): return sqlite3_bind_int64(statement, index, value) == SQLITE_OK
    case .real(let value): return sqlite3_bind_double(statement, index, value) == SQLITE_OK
    case .text(let text):
      // Bind the full UTF-8 byte count so an embedded NUL can't cut the text short.
      var text = text
      return text.withUTF8 {
        sqlite3_bind_text(
          statement, index,
          UnsafeRawPointer($0.baseAddress ?? UnsafePointer(bitPattern: 1)!)
            .assumingMemoryBound(to: CChar.self),
          Int32($0.count), transient) == SQLITE_OK
      }
    case .blob(let data):
      // An empty blob binds as a zero-length blob, not as NULL.
      return data.withUnsafeBytes {
        sqlite3_bind_blob(
          statement, index, $0.baseAddress ?? UnsafeRawPointer(bitPattern: 1), Int32(data.count),
          transient) == SQLITE_OK
      }
    }
  }
}
