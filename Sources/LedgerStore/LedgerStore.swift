import CSQLite
import CryptoKit
import Foundation
import LedgerCore

/// A persistence boundary for a canonical SQLite handle opened and pinned by its caller.
/// It deliberately does not open paths, create databases, or apply migrations.
public final class LedgerStore {
  public struct LedgerReadSnapshot: Sendable {
    public let accounts: [LedgerAccount]
    public let transactions: [LedgerTransactionSnapshot]
    public let revisionHistory: [LedgerTransactionRevision]
    public let undisplayedImportedEventCount: Int
    public let categories: [LedgerCategory]
    public let recurrenceRules: [LedgerRecurrenceRule]
    public let budgets: [LedgerBudget]
    public let installmentPlans: [LedgerInstallmentPlan]
    public let preservedSource: [LedgerPreservedSourceRecord]

    public init(
      accounts: [LedgerAccount], transactions: [LedgerTransactionSnapshot],
      revisionHistory: [LedgerTransactionRevision], undisplayedImportedEventCount: Int,
      categories: [LedgerCategory] = [], recurrenceRules: [LedgerRecurrenceRule] = [],
      budgets: [LedgerBudget] = [], installmentPlans: [LedgerInstallmentPlan] = [],
      preservedSource: [LedgerPreservedSourceRecord] = []
    ) {
      self.accounts = accounts
      self.transactions = transactions
      self.revisionHistory = revisionHistory
      self.undisplayedImportedEventCount = undisplayedImportedEventCount
      self.categories = categories
      self.recurrenceRules = recurrenceRules
      self.budgets = budgets
      self.installmentPlans = installmentPlans
      self.preservedSource = preservedSource
    }
  }

  package struct PortablePackageExportSnapshot: Sendable {
    package let ledger: LedgerReadSnapshot
    package let isRepresentable: Bool
    package let hasImportHistory: Bool
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
    case sqliteFailure(code: Int32)
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

    package init(idempotencyKey: String, draft: LedgerTransactionDraft, createdAt: UTCInstant) {
      self.idempotencyKey = idempotencyKey
      self.draft = draft
      self.createdAt = createdAt
    }
  }

  public struct CorrectTransactionRequest: Sendable {
    package let transactionID: String
    package let expectedCurrentRevisionID: String
    package let draft: LedgerTransactionDraft
    package let createdAt: UTCInstant

    package init(
      transactionID: String, expectedCurrentRevisionID: String, draft: LedgerTransactionDraft,
      createdAt: UTCInstant
    ) {
      self.transactionID = transactionID
      self.expectedCurrentRevisionID = expectedCurrentRevisionID
      self.draft = draft
      self.createdAt = createdAt
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
      let representable = try Self.portablePackageExportIsRepresentable(on: database)
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
        hasImportHistory: importReceiptCount > 0)
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
      accounts: snapshot.accounts, transactions: snapshot.transactions,
      revisionHistory: snapshot.revisionHistory,
      undisplayedImportedEventCount: importedCount,
      categories: try Self.loadCategories(on: database),
      recurrenceRules: try Self.loadRecurrenceRules(on: database),
      budgets: try Self.loadBudgets(on: database),
      installmentPlans: try Self.loadInstallmentPlans(on: database),
      preservedSource: try Self.loadPreservedSource(on: database))
  }

  public func createTransaction(_ request: CreateTransactionRequest) throws -> MutationResult {
    let revision = try preparedRevision(for: request)
    return try mutate { snapshot in
      let status = try Self.insertNew(revision, in: snapshot, on: database)
      try mutationTestHook?(.afterInsertingTransaction)
      return .init(status: status, revision: revision)
    }
  }

  public func createTransfer(
    transfer: CreateTransactionRequest, fee: CreateTransactionRequest?
  ) throws -> (transfer: MutationResult, fee: MutationResult?) {
    let transferRevision = try preparedRevision(for: transfer)
    let feeRevision = try fee.map { try preparedRevision(for: $0) }
    var feeResult: MutationResult?
    let transferResult = try mutate { snapshot in
      let transferStatus = try Self.insertNew(transferRevision, in: snapshot, on: database)
      if let feeRevision {
        let feeStatus = try Self.insertNew(feeRevision, in: snapshot, on: database)
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
        feeResult = .init(status: feeStatus, revision: feeRevision)
      }
      return .init(status: transferStatus, revision: transferRevision)
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
      for revision in revisions {
        let status = try Self.insertNew(revision, in: snapshot, on: database)
        results.append(.init(status: status, revision: revision))
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
    _ revision: LedgerTransactionRevision, in snapshot: LedgerReadSnapshot,
    on database: OpaquePointer
  ) throws -> MutationStatus {
    if let existing = snapshot.revisionHistory.first(where: { $0.id == revision.id }) {
      guard existing == revision else { throw Error.incompatibleCanonicalStore }
      return .unchanged
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
    return .committed
  }

  public func correctTransaction(_ request: CorrectTransactionRequest) throws -> MutationResult {
    try mutate { snapshot in
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
      if let existing = snapshot.revisionHistory.first(where: { $0.id == revision.id }) {
        guard existing == revision else { throw Error.incompatibleCanonicalStore }
        return .init(status: .unchanged, revision: existing)
      }
      guard
        snapshot.transactions.first(where: { $0.id == request.transactionID })?.currentRevision.id
          == predecessor.id
      else {
        throw Error.incompatibleCanonicalStore
      }
      try Self.validateReferences(revision, in: snapshot, on: database)
      try Self.insert(revision, on: database)
      try Self.run(
        "UPDATE main.ledger_transaction SET current_revision_id=? WHERE transaction_id=? AND current_revision_id=?",
        values: [.text(revision.id), .text(request.transactionID), .text(predecessor.id)],
        on: database)
      guard sqlite3_changes(database) == 1 else { throw Error.incompatibleCanonicalStore }
      return .init(status: .committed, revision: revision)
    }
  }

  public func tombstoneTransaction(_ request: TombstoneTransactionRequest) throws -> MutationResult
  {
    try mutate { snapshot in
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
      if let existing = snapshot.revisionHistory.first(where: { $0.id == revision.id }) {
        guard existing == revision else { throw Error.incompatibleCanonicalStore }
        return .init(status: .unchanged, revision: existing)
      }
      guard
        snapshot.transactions.first(where: { $0.id == request.transactionID })?.currentRevision.id
          == predecessor.id
      else {
        throw Error.incompatibleCanonicalStore
      }
      try Self.insert(revision, on: database)
      try Self.run(
        "UPDATE main.ledger_transaction SET current_revision_id=? WHERE transaction_id=? AND current_revision_id=?",
        values: [.text(revision.id), .text(request.transactionID), .text(predecessor.id)],
        on: database)
      guard sqlite3_changes(database) == 1 else { throw Error.incompatibleCanonicalStore }
      return .init(status: .committed, revision: revision)
    }
  }

  public func createAccount(_ account: LedgerAccount) throws {
    _ = try mutate { snapshot in
      if snapshot.accounts.contains(where: { $0.id == account.id }) {
        guard snapshot.accounts.contains(where: { $0 == account }) else {
          throw Error.incompatibleCanonicalStore
        }
        return try Self.placeholderResult(origin: account.origin, status: .unchanged)
      }
      try Self.ensureOrigin(account.origin, on: database)
      try Self.run(
        "INSERT INTO main.ledger_account(account_id, name, currency_unit, origin_id, lifecycle) VALUES (?, ?, ?, ?, ?)",
        values: [
          .text(account.id), .text(account.name), .text(account.currencyUnit),
          .text(account.origin.id), .text(account.lifecycle.rawValue),
        ], on: database)
      return try Self.placeholderResult(origin: account.origin)
    }
  }

  public func createCategory(_ category: LedgerCategory) throws {
    _ = try mutate { snapshot in
      try Self.ensureOrigin(category.origin, on: database)
      try Self.run(
        "INSERT INTO main.ledger_category(category_id, name, kind, origin_id, lifecycle) VALUES (?, ?, ?, ?, ?)",
        values: [
          .text(category.id), .text(category.name), .text(category.kind.rawValue),
          .text(category.origin.id), .text(category.lifecycle.rawValue),
        ], on: database)
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
      for revision in revisions {
        let status = try Self.insertNew(revision, in: snapshot, on: database)
        try mutationTestHook?(.afterInsertingTransaction)
        results.append(.init(status: status, revision: revision))
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
    guard package.formatVersion == LedgerPortablePackageFormat.version,
      package.formatFingerprint == LedgerPortablePackageFormat.fingerprint
    else { throw Error.incompatibleCanonicalStore }
    let origins =
      package.accounts.map(\.origin) + package.categories.map(\.origin)
      + package.revisions.map(\.draft.origin) + package.recurrenceRules.map(\.origin)
      + package.budgets.map(\.origin) + package.installmentPlans.map(\.origin)
    let importedOriginID = String(repeating: "e", count: 64)
    guard package.preservedSource.isEmpty,
      Set(package.accounts.map(\.id)).count == package.accounts.count,
      Set(package.categories.map(\.id)).count == package.categories.count,
      Set(package.revisions.map(\.id)).count == package.revisions.count,
      Set(package.revisions.map { "\($0.transactionID):\($0.revision)" }).count
        == package.revisions.count,
      Set(package.links.map(\.id)).count == package.links.count,
      Set(package.recurrenceRules.map(\.id)).count == package.recurrenceRules.count,
      Set(package.budgets.map(\.id)).count == package.budgets.count,
      Set(package.installmentPlans.map(\.id)).count == package.installmentPlans.count,
      !origins.contains(where: {
        $0.provenanceID != nil || $0.id == importedOriginID
          || $0.label == LedgerOrigin.importedLabel
      }),
      !package.revisions.contains(where: { revision in
        revision.draft.sourceLiterals.contains {
          $0.provenanceID != nil || $0.field == "import.eventID"
        }
      })
    else { throw Error.incompatibleCanonicalStore }
    _ = try mutate { snapshot in
      let tables = CanonicalLedgerSchema.expectedObjects
        .filter { $0.type == "table" && $0.name != "ledger_meta" }.map(\.name)
      guard snapshot.transactions.isEmpty, snapshot.accounts.isEmpty,
        try !Self.hasRows(in: tables, on: database)
      else {
        throw Error.incompatibleCanonicalStore
      }
      for account in package.accounts { try Self.ensureOrigin(account.origin, on: database) }
      for account in package.accounts {
        try Self.run(
          "INSERT INTO main.ledger_account(account_id, name, currency_unit, origin_id, lifecycle) VALUES (?, ?, ?, ?, ?)",
          values: [
            .text(account.id), .text(account.name), .text(account.currencyUnit),
            .text(account.origin.id), .text(account.lifecycle.rawValue),
          ], on: database)
      }
      for category in package.categories {
        try Self.ensureOrigin(category.origin, on: database)
        try Self.run(
          "INSERT INTO main.ledger_category(category_id, name, kind, origin_id, lifecycle) VALUES (?, ?, ?, ?, ?)",
          values: [
            .text(category.id), .text(category.name), .text(category.kind.rawValue),
            .text(category.origin.id), .text(category.lifecycle.rawValue),
          ], on: database)
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
          try Self.insert(revision, on: database)
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
      try mutationTestHook?(.afterApplyingExportCore)
      for rule in package.recurrenceRules { try Self.writeRecurrence(rule, on: database) }
      for budget in package.budgets { try Self.writeBudget(budget, on: database) }
      for plan in package.installmentPlans { try Self.writeInstallment(plan, on: database) }
      return try Self.placeholderResult(
        origin: package.accounts.first?.origin
          ?? LedgerOrigin(id: String(repeating: "1", count: 64), label: "restore"))
    }
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
    on database: OpaquePointer, knownTransactionIDs: Set<String>? = nil
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
    for event in events where !existingTransactions.contains(event.id) {
      if !knownAccounts.contains(event.accountID) {
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
      let revision = try LedgerTransactionRevision(
        id: StableLedgerID.revision(transactionID: event.id, revision: 1),
        transactionID: event.id, revision: 1, predecessorID: nil,
        draft: LedgerTransactionDraft(
          effects: [
            try LedgerTransactionEffect(
              accountID: event.accountID, direction: event.direction, amount: event.amount)
          ], categoryID: nil, kind: event.kind, occurredAt: event.occurredAt,
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
    // Ponytail: Task 4/5 package encoding removes this temporary refusal once these rows
    // have a lossless portable representation.
    let hasFoundationRows = try hasRows(
      in: ["ledger_category_tree", "ledger_account_group", "ledger_account_preferences"],
      on: database)
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
        )
        """, on: database)
    else { throw Error.incompatibleCanonicalStore }
    return !hasFoundationRows && standaloneOriginCount != 1
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

  public func backupCanonicalDatabase(to destination: URL) throws {
    try backupCanonicalDatabase(to: destination, testing: nil)
  }

  package func backupCanonicalDatabase(
    to destination: URL, testing backupTestHook: BackupTestHook?
  ) throws {
    guard destination.isFileURL, destination.path.hasPrefix("/") else {
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

    let parentURL = destination.deletingLastPathComponent()
    let leaf = destination.lastPathComponent
    let parentDescriptor = Darwin.open(
      parentURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard parentDescriptor >= 0, !leaf.isEmpty, leaf != ".", leaf != ".." else {
      if parentDescriptor >= 0 { Darwin.close(parentDescriptor) }
      throw Error.incompatibleCanonicalStore
    }
    defer { Darwin.close(parentDescriptor) }
    let temporaryLeaf = ".ledger-atlas-backup-\(UUID().uuidString).tmp"
    let descriptor = Darwin.openat(
      parentDescriptor, temporaryLeaf,
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
          descriptor, createdIdentity: createdIdentity, parentDescriptor: parentDescriptor,
          temporaryLeaf: temporaryLeaf),
        Self.matchesSerializedPrefix(
          descriptor, serialized: serialized, serializedCount: Int(byteCount)),
        Self.backupTemporaryIsBound(
          descriptor, createdIdentity: createdIdentity, parentDescriptor: parentDescriptor,
          temporaryLeaf: temporaryLeaf)
      {
        _ = ftruncate(descriptor, 0)
        _ = fsync(descriptor)
        if Self.backupTemporaryIsBound(
          descriptor, createdIdentity: createdIdentity, parentDescriptor: parentDescriptor,
          temporaryLeaf: temporaryLeaf)
        {
          _ = unlinkat(parentDescriptor, temporaryLeaf, 0)
        }
        _ = fsync(parentDescriptor)
      }
      Darwin.close(descriptor)
    }
    try backupTestHook?(.afterTemporaryFileCreated)
    var retainedEmptyIdentity = stat()
    var emptyAtPath = stat()
    guard fstat(descriptor, &retainedEmptyIdentity) == 0,
      Self.sameFile(createdIdentity, retainedEmptyIdentity),
      fstatat(parentDescriptor, temporaryLeaf, &emptyAtPath, AT_SYMLINK_NOFOLLOW) == 0,
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
      fstatat(parentDescriptor, temporaryLeaf, &validatedAtPath, AT_SYMLINK_NOFOLLOW) == 0,
      Self.sameFile(retainedValidatedIdentity, validatedAtPath),
      Self.matchesSerializedPrefix(
        descriptor, serialized: serialized, serializedCount: Int(byteCount))
    else { throw Error.incompatibleCanonicalStore }
    try backupTestHook?(.beforeDestinationPublication)
    let publishedIdentity = try Self.publishBackupCopy(
      descriptor, createdIdentity: createdIdentity, parentDescriptor: parentDescriptor,
      temporaryLeaf: temporaryLeaf, destinationLeaf: leaf,
      serialized: serialized, serializedCount: Int(byteCount), testing: backupTestHook)
    guard
      Self.backupTemporaryIsBound(
        descriptor, createdIdentity: createdIdentity, parentDescriptor: parentDescriptor,
        temporaryLeaf: temporaryLeaf)
    else { throw Error.backupPublicationCompleted }
    guard unlinkat(parentDescriptor, temporaryLeaf, 0) == 0, fsync(parentDescriptor) == 0 else {
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
    _ source: Int32, createdIdentity: stat, parentDescriptor: Int32,
    temporaryLeaf: String, destinationLeaf: String, serialized: UnsafePointer<UInt8>,
    serializedCount: Int, testing backupTestHook: BackupTestHook?
  ) throws -> stat {
    guard
      backupTemporaryIsBound(
        source, createdIdentity: createdIdentity, parentDescriptor: parentDescriptor,
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
          source, createdIdentity: createdIdentity, parentDescriptor: parentDescriptor,
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

  package func mutate(_ body: (LedgerReadSnapshot) throws -> MutationResult) throws
    -> MutationResult
  {
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
          try LedgerReceiptTrust.key(for: $0, create: false)
        })
      guard Self.hasNoRows("PRAGMA foreign_key_check", on: database) else {
        throw Error.incompatibleCanonicalStore
      }
      try validateMutationIdentity(requiringNoCompanions: false)
      try Self.execute("COMMIT", on: database)
      return result
    } catch {
      _ = try? Self.execute("ROLLBACK", on: database)
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

  package static func insert(_ revision: LedgerTransactionRevision, on database: OpaquePointer)
    throws
  {
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
    for (ordinal, literal) in revision.draft.sourceLiterals.enumerated() {
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
