import CSQLite
import CryptoKit
import Darwin
import Foundation
import LedgerCore
import LedgerStore

enum CanonicalReadPhase: Sendable {
  case afterDescriptorOpen
  case afterSQLiteOpen
}

enum CanonicalDestinationExpectation: Sendable {
  case absent
  case checksum(String)
}

public struct SQLiteCanonicalCommitter: Sendable {
  private let failAfterEventInserts: Int?
  private let failAfterPreservationInserts: Int?
  private let testingBeforeCanonicalOpen: (@Sendable () -> Void)?
  private let testingAfterCanonicalOpen: (@Sendable () -> Void)?
  private let testingAfterCanonicalCreate: (@Sendable () -> Void)?
  private let testingBeforeCommit: (@Sendable () -> Void)?
  private let testingAfterCommit: (@Sendable () -> Void)?
  private let testingDuringCanonicalRead: (@Sendable (CanonicalReadPhase) -> Void)?

  public init() {
    failAfterEventInserts = nil
    failAfterPreservationInserts = nil
    testingBeforeCanonicalOpen = nil
    testingAfterCanonicalOpen = nil
    testingAfterCanonicalCreate = nil
    testingBeforeCommit = nil
    testingAfterCommit = nil
    testingDuringCanonicalRead = nil
  }

  init(testingFailAfterEventInserts: Int) {
    failAfterEventInserts = testingFailAfterEventInserts
    failAfterPreservationInserts = nil
    testingBeforeCanonicalOpen = nil
    testingAfterCanonicalOpen = nil
    testingAfterCanonicalCreate = nil
    testingBeforeCommit = nil
    testingAfterCommit = nil
    testingDuringCanonicalRead = nil
  }

  init(testingBeforeCanonicalOpen: @escaping @Sendable () -> Void) {
    failAfterEventInserts = nil
    failAfterPreservationInserts = nil
    self.testingBeforeCanonicalOpen = testingBeforeCanonicalOpen
    testingAfterCanonicalOpen = nil
    testingAfterCanonicalCreate = nil
    testingBeforeCommit = nil
    testingAfterCommit = nil
    testingDuringCanonicalRead = nil
  }

  init(testingAfterCanonicalOpen: @escaping @Sendable () -> Void) {
    failAfterEventInserts = nil
    failAfterPreservationInserts = nil
    testingBeforeCanonicalOpen = nil
    self.testingAfterCanonicalOpen = testingAfterCanonicalOpen
    testingAfterCanonicalCreate = nil
    testingBeforeCommit = nil
    testingAfterCommit = nil
    testingDuringCanonicalRead = nil
  }

  init(testingAfterCanonicalCreate: @escaping @Sendable () -> Void) {
    failAfterEventInserts = nil
    failAfterPreservationInserts = nil
    testingBeforeCanonicalOpen = nil
    testingAfterCanonicalOpen = nil
    self.testingAfterCanonicalCreate = testingAfterCanonicalCreate
    testingBeforeCommit = nil
    testingAfterCommit = nil
    testingDuringCanonicalRead = nil
  }

  init(testingBeforeCommit: @escaping @Sendable () -> Void) {
    failAfterEventInserts = nil
    failAfterPreservationInserts = nil
    testingBeforeCanonicalOpen = nil
    testingAfterCanonicalOpen = nil
    testingAfterCanonicalCreate = nil
    self.testingBeforeCommit = testingBeforeCommit
    testingAfterCommit = nil
    testingDuringCanonicalRead = nil
  }

  init(testingAfterCommit: @escaping @Sendable () -> Void) {
    failAfterEventInserts = nil
    failAfterPreservationInserts = nil
    testingBeforeCanonicalOpen = nil
    testingAfterCanonicalOpen = nil
    testingAfterCanonicalCreate = nil
    testingBeforeCommit = nil
    self.testingAfterCommit = testingAfterCommit
    testingDuringCanonicalRead = nil
  }

  init(testingFailAfterPreservationInserts: Int) {
    failAfterEventInserts = nil
    failAfterPreservationInserts = testingFailAfterPreservationInserts
    testingBeforeCanonicalOpen = nil
    testingAfterCanonicalOpen = nil
    testingAfterCanonicalCreate = nil
    testingBeforeCommit = nil
    testingAfterCommit = nil
    testingDuringCanonicalRead = nil
  }

  init(testingDuringCanonicalRead: @escaping @Sendable (CanonicalReadPhase) -> Void) {
    failAfterEventInserts = nil
    failAfterPreservationInserts = nil
    testingBeforeCanonicalOpen = nil
    testingAfterCanonicalOpen = nil
    testingAfterCanonicalCreate = nil
    testingBeforeCommit = nil
    testingAfterCommit = nil
    self.testingDuringCanonicalRead = testingDuringCanonicalRead
  }

  func commit(_ request: CanonicalCommitRequest) throws -> CanonicalCommitResult {
    try commit(request, expecting: nil)
  }

  func commit(
    _ request: CanonicalCommitRequest, expecting destination: CanonicalDestinationExpectation
  ) throws -> CanonicalCommitResult {
    try commit(request, expecting: Optional(destination))
  }

  private func commit(
    _ request: CanonicalCommitRequest, expecting destination: CanonicalDestinationExpectation?
  ) throws -> CanonicalCommitResult {
    let prepared = try prepareCommit(request)
    defer { prepared.snapshot.close() }
    let plan = prepared.plan
    let report = prepared.report
    guard report.blockingCount == 0 else { throw CanonicalCommitError.unsafeMapping }

    let eventSetHash: String
    do {
      eventSetHash = try CanonicalCommitDigest.eventSet(
        request.events, sidecarsByEvent: plan.sidecarsByEvent)
    } catch {
      throw CanonicalCommitError.invalidRequest
    }
    let proofs = request.events.sorted { $0.eventID < $1.eventID }.map {
      CanonicalCommitProof(
        stageDigest: request.expectedStagingDigest,
        sourceSubjectID: $0.sourceRecordID,
        targetEventID: $0.eventID,
        provenanceID: $0.amountProvenance.deterministicID)
    }

    testingBeforeCanonicalOpen?()
    try prepared.snapshot.validatePathIdentity()
    // A pre-existing destination is evidence, not a blank canvas. Authenticate it through
    // the read-only descriptor we pinned before SQLite is ever allowed to open the pathname
    // read-write. In particular, opening a foreign SQLite file read-write can create or alter
    // its journal/WAL even when we later reject its schema.
    let existingIdentity = try authenticateExistingCanonical(
      at: request.canonicalDatabaseURL)
    let opened = try openWritable(
      at: request.canonicalDatabaseURL, expectedExistingIdentity: existingIdentity)
    let database = opened.database
    let requestedV19 = MoneyManagerV19Adapter.admittedProfileIDs.contains(
      request.expectedManifest.profileID)
    let trustKey = try LedgerReceiptTrust.key(
      for: request.canonicalDatabaseURL, create: requestedV19,
      stableIdentity: requestedV19 ? request.expectedManifest.stagingID : nil)
    var transactionOpen = true
    CommitStatementCache.begin(database)
    defer {
      CommitStatementCache.end(database)
      if transactionOpen { _ = execute(database, "ROLLBACK") }
      let isInitial = canonicalStateIsInitial(database)
      sqlite3_close(database)
      if let descriptor = opened.creationDescriptor { Darwin.close(descriptor) }
      if opened.created, isInitial {
        removeCreatedCanonicalIfStillPristine(
          at: request.canonicalDatabaseURL, pinned: opened.pinnedIdentity)
      }
    }
    if existingIdentity != nil {
      try validateNoSQLiteCompanions(at: request.canonicalDatabaseURL)
    }
    // A real backup writes about 800k rows into indexes keyed by hashes, so inserts land in
    // random pages. With the default 2 MB cache SQLite spills pages to disk mid-transaction;
    // 256 MB keeps the working set in memory. It is a per-connection cache limit, not a fixed
    // allocation, and a small ledger never fills it.
    guard execute(database, "PRAGMA foreign_keys=ON"),
      execute(database, "PRAGMA journal_mode=DELETE"),
      execute(database, "PRAGMA cache_size=-262144")
    else { throw CanonicalCommitError.canonicalWriteFailed }
    if existingIdentity != nil {
      try validateNoSQLiteCompanions(at: request.canonicalDatabaseURL)
    }
    guard execute(database, "BEGIN IMMEDIATE") else {
      throw CanonicalCommitError.canonicalWriteFailed
    }
    testingAfterCanonicalOpen?()
    try validateOpenCanonicalIdentity(
      database, path: request.canonicalDatabaseURL, pinned: opened.pinnedIdentity,
      creationDescriptor: opened.creationDescriptor)
    if let destination {
      switch destination {
      case .absent:
        guard opened.created else { throw CanonicalCommitError.idempotencyConflict }
      case .checksum(let expected):
        guard !opened.created, try checksum(database) == expected else {
          throw CanonicalCommitError.idempotencyConflict
        }
      }
    }
    var schemaMigrated = false
    do {
      do {
        schemaMigrated = try ensureSchema(database)
      } catch CanonicalCommitError.incompatibleCanonicalStore {
        // A receipt-bearing ledger with broken membership foreign keys is a damaged retry
        // state, never a new compatible destination. Keep the retry failure fail-closed.
        if try readReceipt(database, idempotencyKey: request.expectedManifest.stagingID) != nil {
          throw CanonicalCommitError.idempotencyConflict
        }
        throw CanonicalCommitError.incompatibleCanonicalStore
      }
      guard try existingCanonicalStateIsHealthy(database, trustKey: trustKey) else {
        throw CanonicalCommitError.idempotencyConflict
      }
      if let receipt = try readReceipt(database, idempotencyKey: request.expectedManifest.stagingID)
      {
        guard receipt.stagingDigest == request.expectedStagingDigest,
          receipt.artifactSHA256 == request.expectedManifest.artifactSHA256,
          receipt.profileID == request.expectedManifest.profileID,
          receipt.adapterVersion == request.expectedManifest.adapterVersion,
          receipt.eventSetHash == eventSetHash,
          receipt.eventCount == request.events.count,
          try canonicalReceiptIntegrityHash(
            database, receipt: request.expectedManifest.stagingID) == receipt.integrityHash
        else { throw CanonicalCommitError.idempotencyConflict }
        guard
          try receiptBackedStateMatches(
            request: request, plan: plan, database: database
          )
        else { throw CanonicalCommitError.idempotencyConflict }
        let canonicalChecksum = try checksum(database)
        if schemaMigrated {
          testingBeforeCommit?()
          try prepared.snapshot.validatePathIdentity()
          try validateOpenCanonicalIdentity(
            database, path: request.canonicalDatabaseURL, pinned: opened.pinnedIdentity,
            creationDescriptor: opened.creationDescriptor)
        }
        guard execute(database, schemaMigrated ? "COMMIT" : "ROLLBACK") else {
          throw CanonicalCommitError.canonicalWriteFailed
        }
        transactionOpen = false
        return CanonicalCommitResult(
          status: .unchanged,
          eventCount: request.events.count,
          canonicalChecksum: canonicalChecksum,
          reconciliationHash: report.reportHash,
          proofs: proofs)
      }

      // A new backup has a new artifact/staging digest. Refuse an identical source row from
      // being inserted under a new event ID; callers must reconcile the snapshot explicitly.
      // This is fail-closed rather than a silent duplicate-import policy.
      guard
        try request.events.allSatisfy({
          try !sourceIdentityAlreadyBound($0, plan: plan, database: database)
        })
      else { throw CanonicalCommitError.idempotencyConflict }

      var insertedEventCount = 0
      for event in request.events.sorted(by: { $0.eventID < $1.eventID }) {
        for binding in event.sourceBindings {
          try insertProvenance(binding.provenance, into: database)
        }
        try insertEvent(event, into: database)
        insertedEventCount += 1
        for binding in event.sourceBindings {
          try insertSourceBinding(binding, eventID: event.eventID, into: database)
        }
        for sidecar in plan.sidecarsByEvent[event.eventID] ?? [] {
          try insertProvenance(sidecar.provenance, into: database)
          try insertSidecar(sidecar, into: database)
        }
        if let failAfterEventInserts, insertedEventCount >= failAfterEventInserts {
          throw CanonicalCommitError.injectedFailure
        }
      }
      for pair in request.transferPairs.sorted(by: { $0.transferID < $1.transferID }) {
        try insertTransferPair(pair, into: database)
      }
      try insertReceipt(
        request: request, integrityHash: String(repeating: "0", count: 64),
        eventSetHash: eventSetHash,
        into: database)
      var insertedPreservationCount = 0
      for anchor in plan.receiptOwnedAnchors {
        try insertReceiptOwnedAnchor(anchor, into: database)
        insertedPreservationCount += 1
        if let failAfterPreservationInserts,
          insertedPreservationCount >= failAfterPreservationInserts
        {
          throw CanonicalCommitError.injectedFailure
        }
      }
      for payload in plan.receiptOwnedPayloads {
        try insertProvenance(payload.provenance, into: database)
        try insertReceiptOwnedPayload(payload, into: database)
        insertedPreservationCount += 1
        if let failAfterPreservationInserts,
          insertedPreservationCount >= failAfterPreservationInserts
        {
          throw CanonicalCommitError.injectedFailure
        }
      }
      try insertReceiptMembership(request: request, plan: plan, into: database)
      do {
        let importedCategoryIDs = try materializeMoneyManagerV19Entities(
          graph: prepared.graph, request: request, database: database)
        try LedgerStore.materializeImportedEvents(
          on: database, categoryIDsByTransactionID: importedCategoryIDs)
      } catch {
        throw CanonicalCommitError.canonicalWriteFailed
      }
      try insertObservedV19Commitments(request: request, plan: plan, into: database)
      guard
        try canonicalEventSetHash(
          database, receipt: request.expectedManifest.stagingID) == eventSetHash
      else { throw CanonicalCommitError.unsafeMapping }
      let integrityHash = try canonicalReceiptIntegrityHash(
        database, receipt: request.expectedManifest.stagingID)
      try run(
        database,
        sql: "UPDATE import_receipt SET reconciliation_hash=? WHERE idempotency_key=?",
        values: [.text(integrityHash), .text(request.expectedManifest.stagingID)])
      if requestedV19 {
        guard let trustKey else { throw CanonicalCommitError.canonicalWriteFailed }
        let signature = LedgerReceiptTrust.signature(
          key: trustKey, receiptID: request.expectedManifest.stagingID,
          integrityHash: integrityHash)
        guard signature.count == 64 else { throw CanonicalCommitError.canonicalWriteFailed }
        try run(
          database,
          sql:
            "INSERT INTO ledger_receipt_trust_anchor(idempotency_key, algorithm, signature) VALUES(?, ?, ?)",
          values: [
            .text(request.expectedManifest.stagingID), .text(LedgerReceiptTrust.algorithm),
            .text(signature),
          ])
      }
      testingBeforeCommit?()
      // The staging descriptor is held for the whole commit. Revalidate after all writes and
      // immediately before COMMIT so a same-inode source mutation cannot be certified.
      try prepared.snapshot.validatePathIdentity()
      try validateOpenCanonicalIdentity(
        database, path: request.canonicalDatabaseURL, pinned: opened.pinnedIdentity,
        creationDescriptor: opened.creationDescriptor)
      let committedChecksum = try checksum(database)
      guard execute(database, "COMMIT") else { throw CanonicalCommitError.canonicalWriteFailed }
      transactionOpen = false
      testingAfterCommit?()
      // No fallible validation follows COMMIT. A durable commit is reported as committed even
      // if an external actor changes a pathname immediately afterward; callers can inspect the
      // returned checksum and the next operation will fail closed on identity mismatch.
      return CanonicalCommitResult(
        status: .committed,
        eventCount: request.events.count,
        canonicalChecksum: committedChecksum,
        reconciliationHash: report.reportHash,
        proofs: proofs)
    } catch let error as CanonicalCommitError {
      throw error
    } catch {
      throw CanonicalCommitError.canonicalWriteFailed
    }
  }

  /// Authenticates staging and derives target-bound reconciliation without opening or writing
  /// the canonical ledger. Blocked decisions are represented in the returned report.
  package func prepare(_ request: CanonicalCommitRequest) throws -> ReconciliationReport {
    let prepared = try prepareCommit(request)
    defer { prepared.snapshot.close() }
    return prepared.report
  }

  public func canonicalChecksum(at url: URL) throws -> String {
    let snapshot = try openReadOnly(at: url)
    defer { snapshot.close() }
    try validateSchema(snapshot.database)
    guard persistedPayloadSizesAreBounded(snapshot.database) else {
      throw CanonicalCommitError.canonicalReadFailed
    }
    let value = try checksum(snapshot.database)
    try snapshot.validatePathIdentity()
    return value
  }

  public func eventCount(at url: URL) throws -> Int {
    let snapshot = try openReadOnly(at: url)
    defer { snapshot.close() }
    try validateSchema(snapshot.database)
    guard let count = scalarInt(snapshot.database, "SELECT count(*) FROM economic_event") else {
      throw CanonicalCommitError.canonicalReadFailed
    }
    try snapshot.validatePathIdentity()
    return count
  }

  public func sidecars(at url: URL, eventID: String) throws -> [CanonicalPersistedSidecar] {
    guard CanonicalIdentifier.isValid(eventID) else { throw CanonicalCommitError.invalidRequest }
    let snapshot = try openReadOnly(at: url)
    defer { snapshot.close() }
    try validateSchema(snapshot.database)
    guard persistedPayloadSizesAreBounded(snapshot.database) else {
      throw CanonicalCommitError.canonicalReadFailed
    }
    let values = try readSidecars(snapshot.database, eventID: eventID)
    try snapshot.validatePathIdentity()
    return values
  }

  public func receiptOwnedPreservation(
    at url: URL, receiptID: String
  ) throws -> CanonicalReceiptOwnedPreservation {
    guard CanonicalIdentifier.isValid(receiptID) else {
      throw CanonicalCommitError.invalidRequest
    }
    let snapshot = try openReadOnly(at: url)
    defer { snapshot.close() }
    try validateSchema(snapshot.database)
    guard persistedPayloadSizesAreBounded(snapshot.database) else {
      throw CanonicalCommitError.canonicalReadFailed
    }
    let value = try readReceiptOwnedPreservation(snapshot.database, receipt: receiptID)
    try snapshot.validatePathIdentity()
    return value
  }

  private func validate(_ request: CanonicalCommitRequest) throws {
    let manifest = request.expectedManifest
    let isMoneyManagerV19 = MoneyManagerV19Adapter.admittedProfileIDs.contains(manifest.profileID)
    guard request.canonicalDatabaseURL.isFileURL, request.stagingDatabaseURL.isFileURL,
      request.canonicalDatabaseURL.standardizedFileURL
        != request.stagingDatabaseURL.standardizedFileURL,
      !isMoneyManagerV19 || request.isObservedV19AdapterAuthorized,
      !request.hasAdapterAuthorization || isMoneyManagerV19,
      !isMoneyManagerV19 || manifest.adapterVersion == MoneyManagerV19Adapter.version,
      manifest.formatVersion == 1,
      CanonicalIdentifier.isValid(manifest.stagingID),
      CanonicalIdentifier.isValid(manifest.artifactSHA256),
      manifest.stagingID
        == StableStagingID.stage(
          artifactSHA256: manifest.artifactSHA256, profileID: manifest.profileID,
          adapterVersion: manifest.adapterVersion),
      CanonicalIdentifier.isValid(request.expectedStagingDigest),
      !request.events.isEmpty
        || (request.isObservedV19AdapterAuthorized
          && request.observedV19ReceiptOwnedSubjectIDs?.isEmpty == false),
      request.events.count <= 1_000_000,
      Set(request.events.map(\.eventID)).count == request.events.count,
      !request.mappingDecisions.contains(where: { $0.disposition == .blocked })
    else { throw CanonicalCommitError.invalidRequest }

    guard
      request.events.allSatisfy({ event in
        event.amountProvenance.artifactSHA256 == manifest.artifactSHA256
          && event.amountProvenance.profileID == manifest.profileID
          && event.amountProvenance.adapterVersion == manifest.adapterVersion
          && event.sidecarReferences.allSatisfy { $0.provenanceID == $0.sidecarID }
      })
        && (request.observedV19ReceiptOwnedSubjectIDs?.allSatisfy(CanonicalIdentifier.isValid)
          ?? true)
    else { throw CanonicalCommitError.unsafeMapping }
    try validateTransferPairs(request)
  }

  /// Every transfer leg is in exactly one pair, each pair joins one debit and one credit on
  /// different accounts, and the pair id is derived from its two legs.
  private func validateTransferPairs(_ request: CanonicalCommitRequest) throws {
    let eventsByID = Dictionary(uniqueKeysWithValues: request.events.map { ($0.eventID, $0) })
    let pairedIDs = request.transferPairs.flatMap { [$0.debitEventID, $0.creditEventID] }
    let transferLegCount = request.events.filter {
      $0.kind == .transferDebit || $0.kind == .transferCredit
    }.count
    guard
      request.transferPairs.allSatisfy({ pair in
        guard let debit = eventsByID[pair.debitEventID],
          let credit = eventsByID[pair.creditEventID]
        else { return false }
        return debit.kind == .transferDebit && credit.kind == .transferCredit
          && debit.accountID != credit.accountID
          && pair.transferID
            == MoneyManagerV19Vocabulary.transferID(
              debitEventID: pair.debitEventID, creditEventID: pair.creditEventID)
      }),
      Set(pairedIDs).count == pairedIDs.count,
      Set(request.transferPairs.map(\.transferID)).count == request.transferPairs.count,
      pairedIDs.count == transferLegCount
    else { throw CanonicalCommitError.unsafeMapping }
  }

  private func insertTransferPair(_ pair: CanonicalTransferPair, into database: OpaquePointer)
    throws
  {
    try run(
      database,
      sql:
        "INSERT INTO economic_event_transfer(transfer_id, debit_event_id, credit_event_id) VALUES(?, ?, ?)",
      values: [.text(pair.transferID), .text(pair.debitEventID), .text(pair.creditEventID)])
  }

  /// The ledger transaction that carries an event: its transfer for a paired leg, else itself.
  private func transactionIDs(for request: CanonicalCommitRequest) -> [String: String] {
    var ids: [String: String] = [:]
    for pair in request.transferPairs {
      ids[pair.debitEventID] = pair.transferID
      ids[pair.creditEventID] = pair.transferID
    }
    return ids
  }

  private func prepareCommit(_ request: CanonicalCommitRequest) throws -> PreparedCommit {
    try validate(request)
    let snapshot = try StagingSnapshot.open(request.stagingDatabaseURL)
    do {
      let graph = try readStagingGraph(snapshot, request: request)
      if request.isObservedV19AdapterAuthorized {
        try MoneyManagerV19ObservedGraph.validate(request, graph: graph)
      }
      let plan = try trustedPlan(for: request, graph: graph)
      let report: ReconciliationReport
      do {
        report = try StagingReconciler().reconcile(
          stagingDatabaseURL: request.stagingDatabaseURL,
          expectedManifest: request.expectedManifest,
          expectedContentDigest: request.expectedStagingDigest,
          decisions: plan.decisions)
      } catch {
        throw CanonicalCommitError.unauthenticatedStaging
      }
      try snapshot.validatePathIdentity()
      return PreparedCommit(snapshot: snapshot, graph: graph, plan: plan, report: report)
    } catch {
      snapshot.close()
      throw error
    }
  }

  private func trustedPlan(
    for request: CanonicalCommitRequest, graph: StagingGraph
  ) throws -> TrustedCommitPlan {
    let eventsByRecord = Dictionary(grouping: request.events, by: \.sourceRecordID)
    let eventsByProvenance = Dictionary(
      grouping:
        request.events.flatMap { event in
          event.sourceBindings.map { ($0.provenance.deterministicID, event) }
        },
      by: \.0
    ).mapValues { $0.map(\.1) }
    var sidecarsByField: [String: [(CanonicalEconomicEvent, CanonicalSidecarReference)]] = [:]
    var persistedSidecarsByEvent: [String: [CanonicalPersistedSidecar]] = [:]
    var supportedTables: [String: [CanonicalEconomicEvent]] = [:]
    var totalSidecarBytes = 0

    for event in request.events {
      guard let record = graph.records[event.sourceRecordID]
      else { throw CanonicalCommitError.unsafeMapping }
      for binding in event.sourceBindings {
        guard let field = graph.fields[binding.provenance.deterministicID],
          let bindingRecord = graph.records[field.recordID],
          let bindingTable = graph.tables[bindingRecord.tableID],
          stagedField(
            field, matches: binding, event: event, manifest: request.expectedManifest,
            record: bindingRecord, table: bindingTable,
            observedV19Authorized: request.isObservedV19AdapterAuthorized)
        else { throw CanonicalCommitError.unsafeMapping }
      }
      supportedTables[record.tableID, default: []].append(event)
      for sidecar in event.sidecarReferences {
        guard let stagedField = graph.fields[sidecar.sidecarID],
          stagedField.recordID == event.sourceRecordID,
          sidecar.provenanceID == sidecar.sidecarID
        else { throw CanonicalCommitError.unsafeMapping }
        guard let sidecarRecord = graph.records[stagedField.recordID],
          let sidecarTable = graph.tables[sidecarRecord.tableID]
        else { throw CanonicalCommitError.unsafeMapping }
        let provenance = FieldProvenance(
          artifactSHA256: request.expectedManifest.artifactSHA256,
          profileID: request.expectedManifest.profileID,
          adapterVersion: request.expectedManifest.adapterVersion,
          locator: SourceLocator(
            containerMember: stagedField.containerMember, table: sidecarTable.name,
            recordKey: sidecarRecord.recordKey, columnOrdinal: stagedField.ordinal,
            columnName: stagedField.columnName), deterministicID: sidecar.sidecarID)
        guard let storageClass = CanonicalFieldStorageClass(rawValue: stagedField.storageClass)
        else { throw CanonicalCommitError.unsafeMapping }
        let persisted = try CanonicalPersistedSidecar(
          sidecarID: sidecar.sidecarID, eventID: event.eventID,
          formatVersion: stagedField.sidecarVersion, declaredType: stagedField.declaredType,
          storageClass: storageClass, payload: stagedField.payload, provenance: provenance,
          maximumBytes: CanonicalCommitDigest.maximumSidecarBytes)
        let (newTotal, overflow) = totalSidecarBytes.addingReportingOverflow(
          persisted.payload.count)
        guard !overflow, newTotal <= CanonicalCommitDigest.maximumTotalSidecarBytes else {
          throw CanonicalCommitError.unsafeMapping
        }
        totalSidecarBytes = newTotal
        persistedSidecarsByEvent[event.eventID, default: []].append(persisted)
        sidecarsByField[sidecar.sidecarID, default: []].append((event, sidecar))
      }
    }

    var receiptOwnedAnchors: [CanonicalReceiptOwnedAnchor] = []
    var receiptOwnedPayloads: [CanonicalReceiptOwnedPayload] = []
    var receiptOwnedAnchorsBySubject: [String: CanonicalReceiptOwnedAnchor] = [:]
    var receiptOwnedPayloadsBySubject: [String: CanonicalReceiptOwnedPayload] = [:]
    if let authorizedSubjects = request.observedV19ReceiptOwnedSubjectIDs {
      for (tableID, table) in graph.tables where authorizedSubjects.contains(tableID) {
        let anchor = try CanonicalReceiptOwnedAnchor(
          anchorID: StableCanonicalID.preservationAnchor(
            stagingID: request.expectedManifest.stagingID, sourceSubjectID: tableID, kind: .table),
          receiptID: request.expectedManifest.stagingID,
          sourceSubjectID: tableID, subjectKind: .table,
          artifactSHA256: request.expectedManifest.artifactSHA256,
          profileID: request.expectedManifest.profileID,
          adapterVersion: request.expectedManifest.adapterVersion,
          containerMember: nil, sourceTable: table.name, sourceRecordKey: nil)
        receiptOwnedAnchors.append(anchor)
        receiptOwnedAnchorsBySubject[tableID] = anchor
      }
      for (recordID, record) in graph.records where authorizedSubjects.contains(recordID) {
        guard let table = graph.tables[record.tableID] else {
          throw CanonicalCommitError.unsafeMapping
        }
        let anchor = try CanonicalReceiptOwnedAnchor(
          anchorID: StableCanonicalID.preservationAnchor(
            stagingID: request.expectedManifest.stagingID, sourceSubjectID: recordID,
            kind: .record),
          receiptID: request.expectedManifest.stagingID,
          sourceSubjectID: recordID, subjectKind: .record,
          artifactSHA256: request.expectedManifest.artifactSHA256,
          profileID: request.expectedManifest.profileID,
          adapterVersion: request.expectedManifest.adapterVersion,
          containerMember: nil, sourceTable: table.name, sourceRecordKey: record.recordKey)
        receiptOwnedAnchors.append(anchor)
        receiptOwnedAnchorsBySubject[recordID] = anchor
      }
      for (fieldID, field) in graph.fields where authorizedSubjects.contains(fieldID) {
        guard let recordAnchor = receiptOwnedAnchorsBySubject[field.recordID],
          recordAnchor.subjectKind == .record,
          let record = graph.records[field.recordID], let table = graph.tables[record.tableID],
          let storageClass = CanonicalFieldStorageClass(rawValue: field.storageClass)
        else { throw CanonicalCommitError.unsafeMapping }
        let provenance = FieldProvenance(
          artifactSHA256: request.expectedManifest.artifactSHA256,
          profileID: request.expectedManifest.profileID,
          adapterVersion: request.expectedManifest.adapterVersion,
          locator: SourceLocator(
            containerMember: field.containerMember, table: table.name,
            recordKey: record.recordKey, columnOrdinal: field.ordinal,
            columnName: field.columnName), deterministicID: fieldID)
        let payload = try CanonicalReceiptOwnedPayload(
          payloadID: StableCanonicalID.preservationPayload(
            receiptID: request.expectedManifest.stagingID,
            anchorID: recordAnchor.anchorID, sourceSubjectID: fieldID,
            formatVersion: field.sidecarVersion, declaredType: field.declaredType,
            storageClass: storageClass, payload: field.payload),
          receiptID: request.expectedManifest.stagingID,
          anchorID: recordAnchor.anchorID, sourceSubjectID: fieldID,
          formatVersion: field.sidecarVersion, declaredType: field.declaredType,
          storageClass: storageClass, payload: field.payload, provenance: provenance,
          maximumBytes: CanonicalCommitDigest.maximumSidecarBytes)
        let (newTotal, overflow) = totalSidecarBytes.addingReportingOverflow(payload.payload.count)
        guard !overflow, newTotal <= CanonicalCommitDigest.maximumTotalSidecarBytes else {
          throw CanonicalCommitError.unsafeMapping
        }
        totalSidecarBytes = newTotal
        receiptOwnedPayloads.append(payload)
        receiptOwnedPayloadsBySubject[fieldID] = payload
      }
      guard
        Set(receiptOwnedAnchorsBySubject.keys).union(receiptOwnedPayloadsBySubject.keys)
          == authorizedSubjects
      else { throw CanonicalCommitError.unsafeMapping }

      // Preserve opaque transaction fields twice: the sidecar is the event representation and
      // this receipt-owned copy is the source-completeness commitment. It lets health reject a
      // rehashed sidecar deletion without changing the frozen v10 schema.
      for (sourceRecordID, effects) in Dictionary(grouping: request.events, by: \.sourceRecordID) {
        guard let record = graph.records[sourceRecordID],
          let table = graph.tables[record.tableID]
        else { throw CanonicalCommitError.unsafeMapping }
        let anchor: CanonicalReceiptOwnedAnchor
        if let existing = receiptOwnedAnchorsBySubject[sourceRecordID] {
          anchor = existing
        } else {
          anchor = try CanonicalReceiptOwnedAnchor(
            anchorID: StableCanonicalID.preservationAnchor(
              stagingID: request.expectedManifest.stagingID, sourceSubjectID: sourceRecordID,
              kind: .record),
            receiptID: request.expectedManifest.stagingID, sourceSubjectID: sourceRecordID,
            subjectKind: .record, artifactSHA256: request.expectedManifest.artifactSHA256,
            profileID: request.expectedManifest.profileID,
            adapterVersion: request.expectedManifest.adapterVersion,
            containerMember: nil, sourceTable: table.name, sourceRecordKey: record.recordKey)
          receiptOwnedAnchors.append(anchor)
          receiptOwnedAnchorsBySubject[sourceRecordID] = anchor
        }
        let boundIDs = Set(effects.flatMap { $0.sourceBindings.map(\.provenance.deterministicID) })
        var opaqueSidecars: [String: CanonicalPersistedSidecar] = [:]
        for sidecar in effects.flatMap({ persistedSidecarsByEvent[$0.eventID, default: []] })
        where !boundIDs.contains(sidecar.provenance.deterministicID) {
          if let existing = opaqueSidecars[sidecar.provenance.deterministicID] {
            guard existing.formatVersion == sidecar.formatVersion,
              existing.declaredType == sidecar.declaredType,
              existing.storageClass == sidecar.storageClass,
              existing.payload == sidecar.payload,
              existing.provenance == sidecar.provenance
            else { throw CanonicalCommitError.unsafeMapping }
            continue
          }
          opaqueSidecars[sidecar.provenance.deterministicID] = sidecar
        }
        for sidecar in opaqueSidecars.values.sorted(by: { $0.sidecarID < $1.sidecarID }) {
          let payload = try CanonicalReceiptOwnedPayload(
            payloadID: StableCanonicalID.preservationPayload(
              receiptID: request.expectedManifest.stagingID, anchorID: anchor.anchorID,
              sourceSubjectID: sidecar.provenance.deterministicID,
              formatVersion: sidecar.formatVersion, declaredType: sidecar.declaredType,
              storageClass: sidecar.storageClass, payload: sidecar.payload),
            receiptID: request.expectedManifest.stagingID, anchorID: anchor.anchorID,
            sourceSubjectID: sidecar.provenance.deterministicID,
            formatVersion: sidecar.formatVersion, declaredType: sidecar.declaredType,
            storageClass: sidecar.storageClass, payload: sidecar.payload,
            provenance: sidecar.provenance,
            maximumBytes: CanonicalCommitDigest.maximumSidecarBytes)
          let (newTotal, overflow) = totalSidecarBytes.addingReportingOverflow(
            payload.payload.count)
          guard !overflow, newTotal <= CanonicalCommitDigest.maximumTotalSidecarBytes else {
            throw CanonicalCommitError.unsafeMapping
          }
          totalSidecarBytes = newTotal
          receiptOwnedPayloads.append(payload)
          receiptOwnedPayloadsBySubject[sidecar.provenance.deterministicID] = payload
        }
      }
    }

    let decisions = try request.mappingDecisions.map { decision in
      let targetComponents: [String]
      switch (decision.kind, decision.disposition, decision.reasonCode) {
      case (.artifact, .preserved, .immutableSourceProvenance)
      where decision.subjectID == request.expectedManifest.stagingID:
        targetComponents = [
          "receipt", request.expectedManifest.stagingID,
          request.expectedManifest.artifactSHA256,
        ]
      case (.table, .mapped, .knownTableAdapter):
        guard let events = supportedTables[decision.subjectID], !events.isEmpty else {
          throw CanonicalCommitError.unsafeMapping
        }
        targetComponents = events.flatMap { [$0.eventID, $0.amountProvenance.deterministicID] }
      case (.record, .mapped, .knownRecordAdapter):
        guard let events = eventsByRecord[decision.subjectID], !events.isEmpty else {
          throw CanonicalCommitError.unsafeMapping
        }
        targetComponents = events.flatMap { [$0.eventID, $0.amountProvenance.deterministicID] }
      case (.field, .mapped, .mappedByAdapter), (.field, .mapped, .knownFieldAdapter):
        guard let events = eventsByProvenance[decision.subjectID], !events.isEmpty else {
          throw CanonicalCommitError.unsafeMapping
        }
        targetComponents = events.flatMap { [$0.eventID, $0.amountProvenance.deterministicID] }
      case (.field, .preserved, .opaqueSidecarPreserved),
        (.field, .preserved, .tombstonePreserved),
        (.field, .preserved, .unresolvedTransactionType),
        (.field, .preserved, .transferDirectionUnproven),
        (.field, .preserved, .unresolvedCategory),
        (.field, .preserved, .unresolvedSourceBinding):
        if let payload = receiptOwnedPayloadsBySubject[decision.subjectID] {
          targetComponents = [
            payload.anchorID, payload.payloadID, payload.provenance.deterministicID,
          ]
          break
        }
        guard let targets = sidecarsByField[decision.subjectID], !targets.isEmpty else {
          throw CanonicalCommitError.unsafeMapping
        }
        targetComponents = targets.flatMap { [$0.0.eventID, $0.1.sidecarID, $0.1.provenanceID] }
      case (.record, .preserved, .opaqueSidecarPreserved),
        (.record, .preserved, .unresolvedTransactionType),
        (.record, .preserved, .transferDirectionUnproven),
        (.record, .preserved, .unresolvedCategory),
        (.record, .preserved, .unresolvedSourceBinding)
      where request.isObservedV19AdapterAuthorized:
        guard let anchor = receiptOwnedAnchorsBySubject[decision.subjectID],
          anchor.subjectKind == .record
        else { throw CanonicalCommitError.unsafeMapping }
        targetComponents = [anchor.anchorID, anchor.sourceSubjectID]
      case (.table, .preserved, .opaqueSidecarPreserved)
      where request.isObservedV19AdapterAuthorized:
        guard let anchor = receiptOwnedAnchorsBySubject[decision.subjectID],
          anchor.subjectKind == .table
        else { throw CanonicalCommitError.unsafeMapping }
        targetComponents = [anchor.anchorID, anchor.sourceSubjectID]
      default:
        throw CanonicalCommitError.unsafeMapping
      }

      let proof = TargetBoundReconciliationProof(
        stageDigest: request.expectedStagingDigest,
        subjectID: decision.subjectID,
        kind: decision.kind,
        disposition: decision.disposition,
        targetComponents: targetComponents)
      let evidence: ReconciliationEvidence?
      switch decision.disposition {
      case .mapped:
        evidence = .canonicalMapping(proof)
      case .preserved:
        evidence = .opaquePreservation(proof)
      case .excluded, .blocked:
        throw CanonicalCommitError.unsafeMapping
      }
      guard let evidence else { throw CanonicalCommitError.unsafeMapping }
      return ReconciliationDecision(
        subjectID: decision.subjectID, kind: decision.kind,
        disposition: decision.disposition, reasonCode: decision.reasonCode,
        evidence: evidence)
    }
    return TrustedCommitPlan(
      decisions: decisions, sidecarsByEvent: persistedSidecarsByEvent,
      receiptOwnedAnchors: receiptOwnedAnchors.sorted { $0.anchorID < $1.anchorID },
      receiptOwnedPayloads: receiptOwnedPayloads.sorted { $0.payloadID < $1.payloadID })
  }

  private func readStagingGraph(
    _ snapshot: StagingSnapshot, request: CanonicalCommitRequest
  ) throws -> StagingGraph {
    let database = snapshot.database
    guard
      CanonicalStagingPreflight.validate(
        database: database, descriptorSize: snapshot.descriptorSize,
        expected: request.expectedManifest),
      (try? SQLiteStagingStore().contentDigest(database: database))
        == request.expectedStagingDigest
    else { throw CanonicalCommitError.unauthenticatedStaging }
    guard
      scalarText(database, "SELECT value FROM staging_meta WHERE key='content_digest'")
        == request.expectedStagingDigest
    else { throw CanonicalCommitError.unauthenticatedStaging }

    var graph = StagingGraph()
    try readRows(
      database,
      sql: "SELECT table_id, table_name FROM staged_table ORDER BY table_id"
    ) { statement in
      guard let id = columnText(statement, 0), let name = columnText(statement, 1) else {
        throw CanonicalCommitError.unauthenticatedStaging
      }
      graph.tables[id] = StagedTableTarget(name: name)
    }
    try readRows(
      database,
      sql: "SELECT record_id, table_id, record_key FROM staged_record ORDER BY record_id"
    ) { statement in
      guard let id = columnText(statement, 0), let tableID = columnText(statement, 1),
        let recordKey = columnText(statement, 2)
      else { throw CanonicalCommitError.unauthenticatedStaging }
      graph.records[id] = StagedRecordTarget(tableID: tableID, recordKey: recordKey)
    }
    try readRows(
      database,
      sql:
        "SELECT field_id, record_id, ordinal, column_name, declared_type, storage_class, payload, sidecar_version, container_member FROM staged_field ORDER BY field_id"
    ) { statement in
      guard let id = columnText(statement, 0), let recordID = columnText(statement, 1),
        sqlite3_column_type(statement, 2) == SQLITE_INTEGER,
        let columnName = columnText(statement, 3), let storageClass = columnText(statement, 5),
        let payload = columnBlob(statement, 6),
        sqlite3_column_type(statement, 7) == SQLITE_INTEGER
      else { throw CanonicalCommitError.unauthenticatedStaging }
      graph.fields[id] = StagedFieldTarget(
        recordID: recordID, ordinal: Int(sqlite3_column_int64(statement, 2)),
        columnName: columnName, declaredType: columnOptionalText(statement, 4),
        storageClass: storageClass, payload: payload,
        sidecarVersion: Int(sqlite3_column_int64(statement, 7)),
        containerMember: columnOptionalText(statement, 8))
    }
    guard
      graph.tables.allSatisfy({ tableID, table in
        tableID
          == StableStagingID.table(
            stagingID: request.expectedManifest.stagingID, table: table.name)
      }),
      graph.records.allSatisfy({ recordID, record in
        guard let table = graph.tables[record.tableID] else { return false }
        return recordID
          == StableStagingID.record(
            stagingID: request.expectedManifest.stagingID, table: table.name,
            recordKey: record.recordKey)
      }),
      graph.fields.allSatisfy({ fieldID, field in
        guard let record = graph.records[field.recordID], let table = graph.tables[record.tableID]
        else { return false }
        return fieldID
          == StableStagingID.field(
            stagingID: request.expectedManifest.stagingID,
            locator: SourceLocator(
              containerMember: field.containerMember, table: table.name,
              recordKey: record.recordKey, columnOrdinal: field.ordinal,
              columnName: field.columnName))
      })
    else { throw CanonicalCommitError.unauthenticatedStaging }
    return graph
  }

  private func stagedField(
    _ field: StagedFieldTarget, matches binding: CanonicalEventSourceBinding,
    event: CanonicalEconomicEvent, manifest: StagingManifest,
    record: StagedRecordTarget, table: StagedTableTarget,
    observedV19Authorized: Bool = false
  ) -> Bool {
    let provenance = binding.provenance
    guard
      field.recordID == event.sourceRecordID
        || (observedV19Authorized && binding.semantic == .currency),
      provenance.artifactSHA256 == manifest.artifactSHA256,
      provenance.profileID == manifest.profileID,
      provenance.adapterVersion == manifest.adapterVersion,
      record.recordKey == provenance.locator.recordKey,
      table.name == provenance.locator.table,
      field.ordinal == provenance.locator.columnOrdinal,
      field.columnName == provenance.locator.columnName,
      field.containerMember == provenance.locator.containerMember,
      field.declaredType == binding.declaredType,
      field.storageClass == binding.storageClass.rawValue,
      observedV19Authorized
        ? (binding.storageClass == .text || binding.storageClass == .integer)
        : binding.storageClass == .text,
      let literal = MoneyManagerV19Vocabulary.mappingLiteral(
        storageClass: field.storageClass, payload: field.payload)
    else { return false }
    if observedV19Authorized {
      if binding.semantic == .currency {
        return literal == event.amount.unitCode
          && MoneyManagerV19Vocabulary.currencyTables.contains(provenance.locator.table)
          && MoneyManagerV19Vocabulary.isoAliases.contains(
            provenance.locator.columnName ?? "")
      }
      return true
    }
    switch binding.semantic {
    case .amount:
      return literal == event.amount.amount.rawLiteral
    case .currency:
      return literal == event.amount.unitCode
    case .occurredAt:
      return literal == temporalBindingLiteral(event.occurredAt)
    case .account:
      return
        (try? StableCanonicalID.account(
          profileID: manifest.profileID, sourceAccountID: literal)) == event.accountID
    case .kind:
      return literal == event.kind.rawValue
    }
  }

  /// Materializes the vendor's account and category entities from the authenticated staging
  /// graph before event revisions are created. Events keep the source row as their provenance;
  /// this pass only supplies the stable canonical references needed by the native ledger.
  private func materializeMoneyManagerV19Entities(
    graph: StagingGraph, request: CanonicalCommitRequest, database: OpaquePointer
  ) throws -> [String: String] {
    guard request.isObservedV19AdapterAuthorized else { return [:] }
    let origin = try LedgerOrigin.imported()
    try run(
      database,
      sql: "INSERT INTO main.ledger_origin(origin_id, label, provenance_id) VALUES (?, ?, ?) ON CONFLICT(origin_id) DO NOTHING",
      values: [.text(origin.id), .text(origin.label), .optionalText(origin.provenanceID)])
    guard try importedOriginMatches(origin, database: database) else {
      throw CanonicalCommitError.unsafeMapping
    }

    var recordIDsByKey: [String: String] = [:]
    for (id, record) in graph.records {
      let key = record.tableID + "\u{0}" + record.recordKey
      recordIDsByKey[key] = min(recordIDsByKey[key] ?? id, id)
    }
    func recordID(for record: StagedRecordTarget, graph _: StagingGraph) -> String {
      recordIDsByKey[record.tableID + "\u{0}" + record.recordKey] ?? ""
    }
    var fieldsByRecord: [String: [StagedFieldTarget]] = [:]
    for field in graph.fields.values { fieldsByRecord[field.recordID, default: []].append(field) }
    func fields(for recordID: String) -> [StagedFieldTarget] {
      fieldsByRecord[recordID] ?? []
    }
    func literal(_ fields: [StagedFieldTarget], aliases: [String]) -> String? {
      for alias in aliases {
        guard let field = fields.first(where: {
          $0.columnName.caseInsensitiveCompare(alias) == .orderedSame
        }) else { continue }
        return MoneyManagerV19Vocabulary.mappingLiteral(
          storageClass: field.storageClass, payload: field.payload)
      }
      return nil
    }
    func nonEmpty(_ value: String?) -> String? {
      guard let value, !value.isEmpty, value != "NULL", value != "null" else { return nil }
      return value
    }
    func validText(_ value: String, maximum: Int) -> Bool {
      !value.isEmpty && value.utf8.count <= maximum && !value.utf8.contains(0)
    }

    let currencyRecords = graph.records.values.filter {
      MoneyManagerV19Vocabulary.currencyTables.contains(graph.tables[$0.tableID]?.name ?? "")
    }
    var currenciesByUID: [String: String] = [:]
    for record in currencyRecords {
      let sourceFields = fields(for: record.recordKey == "" ? "" : recordID(for: record, graph: graph))
      guard let uid = nonEmpty(literal(sourceFields, aliases: MoneyManagerV19Vocabulary.uidAliases)),
        let iso = nonEmpty(literal(sourceFields, aliases: MoneyManagerV19Vocabulary.isoAliases)),
        validText(iso, maximum: 64),
        (try? CurrencyAmount(unitCode: iso, amount: ExactDecimal("0"))) != nil,
        currenciesByUID[uid] == nil
      else { throw CanonicalCommitError.unsafeMapping }
      currenciesByUID[uid] = iso
    }

    let accountRecords = graph.records.values.filter {
      MoneyManagerV19Vocabulary.accountTables.contains(graph.tables[$0.tableID]?.name ?? "")
    }
    var importedAccountsByUID: [String: (id: String, currency: String)] = [:]
    for record in accountRecords.sorted(by: { $0.recordKey < $1.recordKey }) {
      let sourceRecordID = recordID(for: record, graph: graph)
      let sourceFields = fields(for: sourceRecordID)
      guard let uid = nonEmpty(literal(sourceFields, aliases: MoneyManagerV19Vocabulary.uidAliases))
      else { throw CanonicalCommitError.unsafeMapping }
      let accountID = try StableCanonicalID.account(
        profileID: request.expectedManifest.profileID, sourceAccountID: uid)
      let name = nonEmpty(literal(sourceFields, aliases: MoneyManagerV19Vocabulary.nameAliases)) ?? uid
      guard validText(name, maximum: 256) else { throw CanonicalCommitError.unsafeMapping }
      let explicitCurrencyUID = nonEmpty(
        literal(sourceFields, aliases: MoneyManagerV19Vocabulary.currencyUIDAliases))
      let explicitCurrency = explicitCurrencyUID.flatMap { currenciesByUID[$0] }
      if explicitCurrencyUID != nil && explicitCurrency == nil {
        throw CanonicalCommitError.unsafeMapping
      }
      let eventUnits = Set(
        request.events.filter { $0.accountID == accountID }.map { $0.amount.unitCode })
      let inferredCurrency: String?
      if let explicitCurrency {
        inferredCurrency = explicitCurrency
      } else if eventUnits.count == 1 {
        inferredCurrency = eventUnits.first
      } else if currenciesByUID.count == 1 {
        inferredCurrency = currenciesByUID.values.first
      } else {
        inferredCurrency = nil
      }
      guard let currency = inferredCurrency,
        (try? CurrencyAmount(unitCode: currency, amount: ExactDecimal("0"))) != nil
      else { throw CanonicalCommitError.unsafeMapping }
      try insertImportedAccount(
        id: accountID, name: name, currency: currency, origin: origin, database: database)
      importedAccountsByUID[uid] = (accountID, currency)
    }

    let categoryRecords = graph.records.values.filter {
      MoneyManagerV19Vocabulary.categoryTables.contains(graph.tables[$0.tableID]?.name ?? "")
    }
    let categoryRecordIDsByUID: [String: String] = try Dictionary(
      uniqueKeysWithValues: categoryRecords.map { record in
        let sourceRecordID = recordID(for: record, graph: graph)
        let sourceFields = fields(for: sourceRecordID)
        guard let uid = nonEmpty(literal(sourceFields, aliases: MoneyManagerV19Vocabulary.uidAliases))
        else { throw CanonicalCommitError.unsafeMapping }
        return (uid, sourceRecordID)
      })
    var usageByCategory: [String: Set<String>] = [:]
    var categoryUIDByEventID: [String: String] = [:]
    for event in request.events {
      // Transfer legs carry no category; the adapter admits them only when it is empty.
      if event.kind == .transferDebit || event.kind == .transferCredit { continue }
      let sourceFields = fields(for: event.sourceRecordID)
      guard let categoryUID = nonEmpty(
        literal(sourceFields, aliases: MoneyManagerV19Vocabulary.categoryAliases))
      else { throw CanonicalCommitError.unsafeMapping }
      // A balance edit has no category row: the event stays uncategorized.
      if categoryUID == MoneyManagerV19Vocabulary.balanceEditCategoryUID { continue }
      guard categoryRecordIDsByUID[categoryUID] != nil
      else { throw CanonicalCommitError.unsafeMapping }
      let kind = event.kind == .income ? LedgerTransactionKind.income.rawValue
        : LedgerTransactionKind.expense.rawValue
      usageByCategory[categoryUID, default: []].insert(kind)
      categoryUIDByEventID[event.eventID] = categoryUID
    }

    var categoryRows: [ImportedCategoryRow] = []
    var siblingOrders: [String: Int] = [:]
    for record in categoryRecords.sorted(by: { recordID(for: $0, graph: graph) < recordID(for: $1, graph: graph) }) {
      let sourceRecordID = recordID(for: record, graph: graph)
      let sourceFields = fields(for: sourceRecordID)
      guard let uid = nonEmpty(literal(sourceFields, aliases: MoneyManagerV19Vocabulary.uidAliases))
      else { throw CanonicalCommitError.unsafeMapping }
      let parentUID = normalizedParentUID(
        nonEmpty(literal(sourceFields, aliases: MoneyManagerV19Vocabulary.parentCategoryAliases)))
      guard parentUID != uid, parentUID == nil || categoryRecordIDsByUID[parentUID!] != nil
      else { throw CanonicalCommitError.unsafeMapping }
      let name = nonEmpty(literal(sourceFields, aliases: MoneyManagerV19Vocabulary.nameAliases)) ?? uid
      guard validText(name, maximum: 256) else { throw CanonicalCommitError.unsafeMapping }
      let kind: LedgerCategoryKind
      switch usageByCategory[uid, default: []] {
      case [LedgerTransactionKind.income.rawValue]: kind = .income
      case [LedgerTransactionKind.expense.rawValue]: kind = .expense
      default: kind = .neutral
      }
      let siblingKey = parentUID ?? ""
      let displayOrder = siblingOrders[siblingKey, default: 0]
      siblingOrders[siblingKey] = displayOrder + 1
      categoryRows.append(
        ImportedCategoryRow(
          uid: uid, id: try StableCanonicalID.category(
            profileID: request.expectedManifest.profileID, sourceCategoryID: uid),
          name: name, kind: kind, parentUID: parentUID, displayOrder: displayOrder))
    }
    let categoryIDsByUID = Dictionary(uniqueKeysWithValues: categoryRows.map { ($0.uid, $0.id) })
    var pending = categoryRows
    var insertedUIDs: Set<String> = []
    while !pending.isEmpty {
      let ready = pending.filter { $0.parentUID == nil || insertedUIDs.contains($0.parentUID!) }
      guard !ready.isEmpty else { throw CanonicalCommitError.unsafeMapping }
      for row in ready.sorted(by: { $0.id < $1.id }) {
        let parentID = row.parentUID.flatMap { categoryIDsByUID[$0] }
        try insertImportedCategory(
          id: row.id, name: row.name, kind: row.kind, parentID: parentID,
          displayOrder: row.displayOrder, origin: origin, database: database)
        insertedUIDs.insert(row.uid)
      }
      pending.removeAll { insertedUIDs.contains($0.uid) }
    }

    try materializeMoneyManagerV19Recurrences(
      graph: graph, request: request, origin: origin, accountsByUID: importedAccountsByUID,
      categoriesByUID: Dictionary(uniqueKeysWithValues: categoryRows.map { ($0.uid, $0) }),
      currenciesByUID: currenciesByUID, database: database)

    var eventCategoryIDs: [String: String] = [:]
    for event in request.events {
      // The first pass throws for every event except balance edits and transfer legs, which
      // stay uncategorized.
      guard let categoryUID = categoryUIDByEventID[event.eventID] else { continue }
      guard let row = categoryRows.first(where: { $0.uid == categoryUID })
      else { throw CanonicalCommitError.unsafeMapping }
      let compatible = (row.kind == .income && event.kind == .income)
        || (row.kind == .expense && event.kind == .expense)
      if compatible { eventCategoryIDs[event.eventID] = row.id }
    }
    return eventCategoryIDs
  }

  /// Maps REPEATTRANSACTION rows that Ledger Atlas can express exactly into recurring rules.
  /// A rule starts on its NEXT_DATE, so occurrences Money Manager already generated (imported
  /// as plain transactions) are never generated twice. A rule that cannot be mapped exactly
  /// (unknown schedule, transfer, inexact REAL amount, unresolved account) is skipped and
  /// stays byte-preserved in the receipt; it never blocks the import.
  private func materializeMoneyManagerV19Recurrences(
    graph: StagingGraph, request: CanonicalCommitRequest, origin: LedgerOrigin,
    accountsByUID: [String: (id: String, currency: String)],
    categoriesByUID: [String: ImportedCategoryRow], currenciesByUID: [String: String],
    database: OpaquePointer
  ) throws {
    guard let zone = request.observedV19SourceTimeZone else { return }
    let zoneColumns: (String, String)
    if let identifier = zone.ianaIdentifier {
      zoneColumns = ("iana", identifier)
    } else if let offset = zone.fixedOffsetSeconds {
      zoneColumns = ("fixed", String(offset))
    } else {
      return
    }
    let fieldsByRecord = Dictionary(grouping: graph.fields.values, by: \.recordID)
    for (recordID, record) in graph.records.sorted(by: { $0.key < $1.key }) {
      guard let table = graph.tables[record.tableID],
        MoneyManagerV19Vocabulary.recurrenceTables.contains(table.name)
      else { continue }
      let fields = fieldsByRecord[recordID] ?? []
      func field(_ aliases: [String]) -> StagedFieldTarget? {
        for alias in aliases {
          if let match = fields.first(where: {
            $0.columnName.caseInsensitiveCompare(alias) == .orderedSame
          }) { return match }
        }
        return nil
      }
      func text(_ aliases: [String]) -> String? {
        guard let match = field(aliases),
          let value = MoneyManagerV19Vocabulary.mappingLiteral(
            storageClass: match.storageClass, payload: match.payload),
          !value.isEmpty, value != "NULL", value != "null"
        else { return nil }
        return value
      }
      guard let uid = text(MoneyManagerV19Vocabulary.uidAliases),
        let code = text(MoneyManagerV19Vocabulary.repeatTypeAliases),
        let schedule = MoneyManagerV19Vocabulary.recurrence(forRepeatType: code),
        let doType = text(MoneyManagerV19Vocabulary.doTypeAliases),
        doType == "0" || doType == "1",
        text(MoneyManagerV19Vocabulary.toAssetAliases) == nil,
        let accountUID = text(MoneyManagerV19Vocabulary.assetAliases),
        let account = accountsByUID[accountUID],
        let amountField = field(MoneyManagerV19Vocabulary.recurrenceAmountAliases),
        amountField.storageClass == CanonicalFieldStorageClass.real.rawValue,
        let amount = MoneyManagerV19Vocabulary.recurrenceAmountLiteral(
          realPayload: amountField.payload),
        let nextLiteral = text(MoneyManagerV19Vocabulary.nextDateAliases),
        let nextMilliseconds = Int64(nextLiteral),
        let start = MoneyManagerV19Vocabulary.localDate(
          epochMilliseconds: nextMilliseconds, in: zone)
      else { continue }
      let endLiteral = text(MoneyManagerV19Vocabulary.endDateAliases) ?? "0"
      guard endLiteral == "0" else { continue }
      let currency: String
      if let currencyUID = text(MoneyManagerV19Vocabulary.currencyUIDAliases) {
        guard let iso = currenciesByUID[currencyUID] else { continue }
        currency = iso
      } else {
        currency = account.currency
      }
      guard currency == account.currency else { continue }
      let kind: LedgerTransactionKind = doType == "0" ? .income : .expense
      let categoryID = text(MoneyManagerV19Vocabulary.categoryAliases)
        .flatMap { categoriesByUID[$0] }
        .flatMap { row -> String? in
          (row.kind == .income && kind == .income) || (row.kind == .expense && kind == .expense)
            ? row.id : nil
        }
      let deleted = (text(MoneyManagerV19Vocabulary.deletedAliases) ?? "0") != "0"
      let ruleID = MoneyManagerV19Vocabulary.recurrenceRuleID(
        profileID: request.expectedManifest.profileID, sourceRuleUID: uid)
      try run(
        database,
        sql: """
          INSERT INTO main.ledger_recurrence_rule(
            rule_id, origin_id, account_id, category_id, kind, amount_literal, currency_unit,
            frequency, interval, day_of_month, timezone_kind, timezone_value, start_year,
            start_month, start_day, until_year, until_month, until_day, paused, skipped, lifecycle
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, 0, '', ?)
          ON CONFLICT(rule_id) DO NOTHING
          """,
        values: [
          .text(ruleID), .text(origin.id), .text(account.id), .optionalText(categoryID),
          .text(kind.rawValue), .text(amount), .text(currency),
          .text(schedule.frequency.rawValue), .int(schedule.interval),
          .optionalInt(schedule.frequency == .monthly ? start.day : nil),
          .text(zoneColumns.0), .text(zoneColumns.1),
          .int(start.year), .int(start.month), .int(start.day),
          .text(deleted ? LedgerLifecycleState.tombstoned.rawValue
            : LedgerLifecycleState.active.rawValue),
        ])
    }
  }

  private func normalizedParentUID(_ value: String?) -> String? {
    guard let value else { return nil }
    switch value.trimmingCharacters(in: .whitespacesAndNewlines) {
    case "", "0", "-1", "NULL", "null": return nil
    default: return value
    }
  }

  private func importedOriginMatches(_ origin: LedgerOrigin, database: OpaquePointer) throws -> Bool {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
      database,
      "SELECT label, provenance_id FROM main.ledger_origin WHERE origin_id=?",
      -1, &statement, nil) == SQLITE_OK,
      let statement, bind(.text(origin.id), to: statement, at: 1)
    else { throw CanonicalCommitError.canonicalWriteFailed }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return false }
    return columnText(statement, 0) == origin.label
      && columnOptionalText(statement, 1) == origin.provenanceID
  }

  private func insertImportedAccount(
    id: String, name: String, currency: String, origin: LedgerOrigin, database: OpaquePointer
  ) throws {
    guard try countRows(
      database, sql: "SELECT count(*) FROM main.ledger_account WHERE account_id=?",
      values: [.text(id)]) == 0 else {
      guard try accountMatches(id: id, name: name, currency: currency, origin: origin, database: database)
      else { throw CanonicalCommitError.unsafeMapping }
      return
    }
    try run(
      database,
      sql: "INSERT INTO main.ledger_account(account_id, name, currency_unit, origin_id, lifecycle) VALUES (?, ?, ?, ?, ?)",
      values: [
        .text(id), .text(name), .text(currency), .text(origin.id),
        .text(LedgerLifecycleState.active.rawValue),
      ])
  }

  private func accountMatches(
    id: String, name: String, currency: String, origin: LedgerOrigin, database: OpaquePointer
  ) throws -> Bool {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
      database,
      "SELECT name, currency_unit, origin_id, lifecycle FROM main.ledger_account WHERE account_id=?",
      -1, &statement, nil) == SQLITE_OK,
      let statement, bind(.text(id), to: statement, at: 1)
    else { throw CanonicalCommitError.canonicalReadFailed }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return false }
    return columnText(statement, 0) == name && columnText(statement, 1) == currency
      && columnText(statement, 2) == origin.id
      && columnText(statement, 3) == LedgerLifecycleState.active.rawValue
  }

  private func insertImportedCategory(
    id: String, name: String, kind: LedgerCategoryKind, parentID: String?, displayOrder: Int,
    origin: LedgerOrigin, database: OpaquePointer
  ) throws {
    let existing = try countRows(
      database, sql: "SELECT count(*) FROM main.ledger_category WHERE category_id=?",
      values: [.text(id)])
    if existing == 0 {
      try run(
        database,
        sql: "INSERT INTO main.ledger_category(category_id, name, kind, origin_id, lifecycle) VALUES (?, ?, ?, ?, ?)",
        values: [
          .text(id), .text(name), .text(kind.rawValue), .text(origin.id),
          .text(LedgerLifecycleState.active.rawValue),
        ])
      try run(
        database,
        sql: "INSERT INTO main.ledger_category_tree(category_id, parent_category_id, display_order, hidden) VALUES (?, ?, ?, ?)",
        values: [.text(id), .optionalText(parentID), .int(displayOrder), .int(0)])
    }
    guard try categoryMatches(
      id: id, name: name, kind: kind, parentID: parentID, displayOrder: displayOrder,
      origin: origin, database: database)
    else { throw CanonicalCommitError.unsafeMapping }
  }

  private func categoryMatches(
    id: String, name: String, kind: LedgerCategoryKind, parentID: String?, displayOrder: Int,
    origin: LedgerOrigin, database: OpaquePointer
  ) throws -> Bool {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
      database,
      "SELECT c.name, c.kind, c.origin_id, c.lifecycle, t.parent_category_id, t.display_order, t.hidden FROM main.ledger_category c LEFT JOIN main.ledger_category_tree t ON t.category_id=c.category_id WHERE c.category_id=?",
      -1, &statement, nil) == SQLITE_OK,
      let statement, bind(.text(id), to: statement, at: 1)
    else { throw CanonicalCommitError.canonicalReadFailed }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return false }
    let storedParent = columnOptionalText(statement, 4)
    let storedOrder = sqlite3_column_type(statement, 5) == SQLITE_NULL ? 0 : Int(sqlite3_column_int64(statement, 5))
    let storedHidden = sqlite3_column_type(statement, 6) == SQLITE_NULL ? false : sqlite3_column_int(statement, 6) == 1
    return columnText(statement, 0) == name && columnText(statement, 1) == kind.rawValue
      && columnText(statement, 2) == origin.id
      && columnText(statement, 3) == LedgerLifecycleState.active.rawValue
      && storedParent == parentID && storedOrder == displayOrder && !storedHidden
  }

  private func temporalBindingLiteral(_ value: SourceTemporal) -> String {
    let zone =
      value.timeZone.ianaIdentifier.map { "iana:\($0)" }
      ?? "fixed:\(value.timeZone.fixedOffsetSeconds!)"
    let date = value.localDateTime.date
    return [
      String(value.instant.epochMilliseconds), String(date.year), String(date.month),
      String(date.day), String(value.localDateTime.hour), String(value.localDateTime.minute),
      String(value.localDateTime.second), String(value.localDateTime.millisecond), zone,
      value.precision.rawValue, String(value.resolvedOffsetSeconds),
    ].joined(separator: "|")
  }

  private func readRows(
    _ database: OpaquePointer, sql: String,
    consume: (OpaquePointer) throws -> Void
  ) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw CanonicalCommitError.unauthenticatedStaging }
    defer { sqlite3_finalize(statement) }
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { return }
      guard result == SQLITE_ROW else { throw CanonicalCommitError.unauthenticatedStaging }
      try consume(statement)
    }
  }

  private func authenticateExistingCanonical(at url: URL) throws -> stat? {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      guard errno == ENOENT else { throw CanonicalCommitError.incompatibleCanonicalStore }
      return nil
    }
    defer { Darwin.close(descriptor) }

    var identity = stat()
    var atPath = stat()
    guard fstat(descriptor, &identity) == 0,
      lstat(url.path, &atPath) == 0,
      sameFile(identity, atPath)
    else { throw CanonicalCommitError.incompatibleCanonicalStore }
    try validatePinnedFile(identity)
    // A live rollback journal, WAL, or shared-memory file means this pathname is not a
    // self-contained canonical store. Refuse it before SQLite is allowed to open the
    // destination read-write: SQLite may otherwise recover or checkpoint the foreign
    // state as an incidental consequence of opening it.
    try validateNoSQLiteCompanions(at: url)

    // Opening /dev/fd/N keeps SQLite bound to the O_NOFOLLOW descriptor, rather than
    // reopening an attacker-controlled path. This remains read-only, so it cannot perform recovery writes; do not use immutable=1
    // here because that masks the header's actual journal mode.
    let sqliteDescriptor = dup(descriptor)
    guard sqliteDescriptor >= 0 else { throw CanonicalCommitError.canonicalReadFailed }
    defer { Darwin.close(sqliteDescriptor) }
    var database: OpaquePointer?
    let uri = "file:/dev/fd/\(sqliteDescriptor)?mode=ro"
    guard
      sqlite3_open_v2(
        uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
        == SQLITE_OK,
      let database,
      sqlite3_db_readonly(database, "main") == 1
    else {
      if database != nil { sqlite3_close(database) }
      throw CanonicalCommitError.incompatibleCanonicalStore
    }
    defer { sqlite3_close(database) }
    try validateSchemaIdentity(database, allowingLegacyV8: true)
    try validateCanonicalJournalMode(database)

    var afterAuthentication = stat()
    var afterPathAuthentication = stat()
    guard fstat(descriptor, &afterAuthentication) == 0,
      lstat(url.path, &afterPathAuthentication) == 0,
      sameFile(identity, afterAuthentication), sameFile(identity, afterPathAuthentication)
    else { throw CanonicalCommitError.incompatibleCanonicalStore }
    try validateNoSQLiteCompanions(at: url)
    return identity
  }

  private func openWritable(at url: URL, expectedExistingIdentity: stat?) throws
    -> OpenedCanonicalDatabase
  {
    var pinned = stat()
    var created = false
    var creationDescriptor: Int32?
    var openedSuccessfully = false
    defer {
      if created && !openedSuccessfully {
        removeCreatedCanonicalIfStillPristine(at: url, pinned: pinned)
      }
    }
    if lstat(url.path, &pinned) != 0 {
      guard errno == ENOENT else { throw CanonicalCommitError.incompatibleCanonicalStore }
      guard expectedExistingIdentity == nil else {
        throw CanonicalCommitError.incompatibleCanonicalStore
      }
      let descriptor = Darwin.open(
        url.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        mode_t(S_IRUSR | S_IWUSR))
      guard descriptor >= 0 else { throw CanonicalCommitError.canonicalWriteFailed }
      guard fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0,
        fstat(descriptor, &pinned) == 0
      else {
        Darwin.close(descriptor)
        throw CanonicalCommitError.canonicalWriteFailed
      }
      created = true
      testingAfterCanonicalCreate?()
      var atPath = stat()
      guard lstat(url.path, &atPath) == 0, sameFile(pinned, atPath) else {
        Darwin.close(descriptor)
        throw CanonicalCommitError.incompatibleCanonicalStore
      }
      creationDescriptor = descriptor
    } else if let expectedExistingIdentity {
      guard sameFile(expectedExistingIdentity, pinned) else {
        throw CanonicalCommitError.incompatibleCanonicalStore
      }
      try validateNoSQLiteCompanions(at: url)
    } else {
      // A file appearing after the read-only authentication pass is not a destination we
      // may initialize or modify.
      throw CanonicalCommitError.incompatibleCanonicalStore
    }
    try validatePinnedFile(pinned)
    var database: OpaquePointer?
    guard
      sqlite3_open_v2(
        url.path, &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
      let database
    else {
      if database != nil { sqlite3_close(database) }
      if let creationDescriptor { Darwin.close(creationDescriptor) }
      throw CanonicalCommitError.canonicalWriteFailed
    }
    do {
      try validateOpenCanonicalIdentity(
        database, path: url, pinned: pinned, creationDescriptor: creationDescriptor)
      if expectedExistingIdentity != nil {
        try validateNoSQLiteCompanions(at: url)
      }
    } catch {
      sqlite3_close(database)
      if let creationDescriptor { Darwin.close(creationDescriptor) }
      throw error
    }
    sqlite3_busy_timeout(database, 5_000)
    openedSuccessfully = true
    return OpenedCanonicalDatabase(
      database: database, pinnedIdentity: pinned, created: created,
      creationDescriptor: creationDescriptor)
  }

  private func openReadOnly(at url: URL) throws -> CanonicalReadSnapshot {
    try validateNoSQLiteCompanions(at: url)
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw CanonicalCommitError.canonicalReadFailed }
    var pinned = stat()
    var atPath = stat()
    guard fstat(descriptor, &pinned) == 0, lstat(url.path, &atPath) == 0,
      CanonicalReadSnapshot.sameIdentity(pinned, atPath)
    else {
      Darwin.close(descriptor)
      throw CanonicalCommitError.incompatibleCanonicalStore
    }
    do {
      try validatePinnedFile(pinned)
    } catch {
      Darwin.close(descriptor)
      throw error
    }
    testingDuringCanonicalRead?(.afterDescriptorOpen)
    let sqliteDescriptor = dup(descriptor)
    guard sqliteDescriptor >= 0 else {
      Darwin.close(descriptor)
      throw CanonicalCommitError.canonicalReadFailed
    }
    defer { Darwin.close(sqliteDescriptor) }
    var database: OpaquePointer?
    let uri = "file:/dev/fd/\(sqliteDescriptor)?mode=ro"
    guard
      sqlite3_open_v2(
        uri, &database,
        SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
      let database
    else {
      if database != nil { sqlite3_close(database) }
      Darwin.close(descriptor)
      throw CanonicalCommitError.canonicalReadFailed
    }
    testingDuringCanonicalRead?(.afterSQLiteOpen)
    let snapshot = CanonicalReadSnapshot(
      database: database, descriptor: descriptor, identity: pinned, url: url)
    do {
      try snapshot.validatePathIdentity()
      try validateNoSQLiteCompanions(at: url)
    } catch {
      snapshot.close()
      throw error
    }
    return snapshot
  }

  private func validatePinnedFile(_ value: stat) throws {
    guard (value.st_mode & S_IFMT) == S_IFREG, value.st_uid == getuid(), value.st_nlink == 1,
      (value.st_mode & mode_t(0o777)) == mode_t(S_IRUSR | S_IWUSR)
    else { throw CanonicalCommitError.incompatibleCanonicalStore }
  }

  private func sameFile(_ left: stat, _ right: stat) -> Bool {
    left.st_dev == right.st_dev && left.st_ino == right.st_ino
  }

  private func validateOpenCanonicalIdentity(
    _ database: OpaquePointer, path: URL, pinned: stat, creationDescriptor: Int32? = nil
  ) throws {
    var atPath = stat()
    guard lstat(path.path, &atPath) == 0, sameFile(pinned, atPath) else {
      throw CanonicalCommitError.incompatibleCanonicalStore
    }
    if let creationDescriptor {
      var descriptorIdentity = stat()
      guard fstat(creationDescriptor, &descriptorIdentity) == 0,
        sameFile(pinned, descriptorIdentity)
      else {
        throw CanonicalCommitError.incompatibleCanonicalStore
      }
    }
    var hasMoved: Int32 = 0
    guard sqlite3_file_control(database, "main", SQLITE_FCNTL_HAS_MOVED, &hasMoved) == SQLITE_OK,
      hasMoved == 0
    else { throw CanonicalCommitError.incompatibleCanonicalStore }
  }

  private func validateNoSQLiteCompanions(at url: URL) throws {
    for suffix in ["-journal", "-wal", "-shm"] {
      var companion = stat()
      errno = 0
      guard lstat(url.path + suffix, &companion) != 0, errno == ENOENT else {
        throw CanonicalCommitError.incompatibleCanonicalStore
      }
    }
  }

  private func validateCanonicalJournalMode(_ database: OpaquePointer) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA journal_mode", -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw CanonicalCommitError.incompatibleCanonicalStore }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
      let mode = sqlite3_column_text(statement, 0)
    else { throw CanonicalCommitError.incompatibleCanonicalStore }
    guard String(cString: mode).lowercased() == "delete" else {
      throw CanonicalCommitError.incompatibleCanonicalStore
    }
  }

  private func canonicalStateIsInitial(_ database: OpaquePointer) -> Bool {
    scalarInt(database, "SELECT count(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'") == 0
  }

  private func removeCreatedCanonicalIfStillPristine(at path: URL, pinned: stat) {
    var current = stat()
    guard lstat(path.path, &current) == 0, sameFile(pinned, current),
      (try? validatePinnedFile(current)) != nil,
      current.st_size == 0
    else { return }
    _ = unlink(path.path)
  }

  private func ensureSchema(_ database: OpaquePointer) throws -> Bool {
    var migrated = false
    guard
      let objectCount = scalarInt(
        database, "SELECT count(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'")
    else { throw CanonicalCommitError.canonicalReadFailed }
    if objectCount == 0 {
      guard execute(database, "PRAGMA application_id=\(CanonicalLedgerSchema.applicationID)") else {
        throw CanonicalCommitError.canonicalWriteFailed
      }
      for statement in CanonicalLedgerSchema.creationStatements {
        guard execute(database, statement) else {
          throw CanonicalCommitError.canonicalWriteFailed
        }
      }
      try insertMeta(database, key: "schema_version", value: String(CanonicalLedgerSchema.version))
      try insertMeta(database, key: "ledger_identity", value: "ledger-atlas-canonical")
      try insertMeta(database, key: "schema_fingerprint", value: CanonicalLedgerSchema.fingerprint)
    } else if scalarText(database, "SELECT value FROM ledger_meta WHERE key='schema_version'")
      == "8"
    {
      let objects = schemaObjects(database)
      guard
        scalarInt(database, "PRAGMA application_id") == Int(CanonicalLedgerSchema.applicationID),
        scalarText(database, "SELECT value FROM ledger_meta WHERE key='ledger_identity'")
          == "ledger-atlas-canonical",
        scalarText(database, "SELECT value FROM ledger_meta WHERE key='schema_fingerprint'")
          == CanonicalLedgerSchema.legacyV8Fingerprint,
        scalarInt(database, "SELECT count(*) FROM ledger_meta") == 3,
        tableNames(database) == CanonicalLedgerSchema.legacyV8TableNames,
        CanonicalLedgerSchema.schemaFingerprint(for: objects)
          == CanonicalLedgerSchema.legacyV8Fingerprint
      else { throw CanonicalCommitError.incompatibleCanonicalStore }
      for statement in CanonicalLedgerSchema.v8ToV9MigrationStatements {
        guard execute(database, statement) else { throw CanonicalCommitError.canonicalWriteFailed }
      }
      guard
        execute(
          database,
          "UPDATE ledger_meta SET value='9' WHERE key='schema_version'")
      else { throw CanonicalCommitError.canonicalWriteFailed }
      migrated = true
    }
    if let current = scalarText(
      database, "SELECT value FROM ledger_meta WHERE key='schema_version'"),
      let version = Int(current), version < CanonicalLedgerSchema.version
    {
      var cursor = version
      while cursor < CanonicalLedgerSchema.version {
        guard
          let statements = CanonicalLedgerSchema.additiveMigrationStatements(fromVersion: cursor)
        else { throw CanonicalCommitError.incompatibleCanonicalStore }
        for statement in statements {
          guard execute(database, statement) else {
            throw CanonicalCommitError.canonicalWriteFailed
          }
        }
        cursor += 1
      }
      guard
        execute(
          database,
          "UPDATE ledger_meta SET value='\(CanonicalLedgerSchema.version)' WHERE key='schema_version'"
        ),
        execute(
          database,
          "UPDATE ledger_meta SET value='\(CanonicalLedgerSchema.fingerprint)' WHERE key='schema_fingerprint'"
        )
      else { throw CanonicalCommitError.canonicalWriteFailed }
      migrated = true
    }
    try validateSchema(database)
    return migrated
  }

  private func validateSchema(_ database: OpaquePointer) throws {
    try validateSchemaIdentity(database)
    guard scalarText(database, "PRAGMA quick_check") == "ok",
      queryHasNoRows(database, "PRAGMA foreign_key_check")
    else { throw CanonicalCommitError.incompatibleCanonicalStore }
  }

  private func validateSchemaIdentity(_ database: OpaquePointer, allowingLegacyV8: Bool = false)
    throws
  {
    let expectedTables = CanonicalLedgerSchema.expectedObjects
      .filter { $0.type == "table" }.map(\.name).sorted()
    let legacyTables = CanonicalLedgerSchema.legacyV8TableNames
    guard scalarInt(database, "PRAGMA application_id") == Int(CanonicalLedgerSchema.applicationID),
      scalarText(database, "SELECT value FROM ledger_meta WHERE key='ledger_identity'")
        == "ledger-atlas-canonical",
      scalarInt(database, "SELECT count(*) FROM ledger_meta") == 3
    else { throw CanonicalCommitError.incompatibleCanonicalStore }
    let current =
      scalarText(database, "SELECT value FROM ledger_meta WHERE key='schema_version'")
      == String(CanonicalLedgerSchema.version)
      && scalarText(database, "SELECT value FROM ledger_meta WHERE key='schema_fingerprint'")
        == CanonicalLedgerSchema.fingerprint
      && tableNames(database) == expectedTables
      && schemaObjects(database) == CanonicalLedgerSchema.expectedObjects
    let legacyObjects = schemaObjects(database)
    let legacy =
      allowingLegacyV8
      && scalarText(database, "SELECT value FROM ledger_meta WHERE key='schema_version'") == "8"
      && scalarText(database, "SELECT value FROM ledger_meta WHERE key='schema_fingerprint'")
        == CanonicalLedgerSchema.legacyV8Fingerprint
      && tableNames(database) == legacyTables
      && CanonicalLedgerSchema.schemaFingerprint(for: legacyObjects)
        == CanonicalLedgerSchema.legacyV8Fingerprint
    // Any frozen release on the lifecycle upgrade chain (v10, v11, ...) may extend additively.
    let chainRelease = scalarText(
      database, "SELECT value FROM ledger_meta WHERE key='schema_version'"
    ).flatMap(Int.init).flatMap { version in
      scalarText(database, "SELECT value FROM ledger_meta WHERE key='schema_fingerprint'")
        .flatMap {
          CanonicalLedgerSchema.lifecycleLegacyRelease(version: version, fingerprint: $0)
        }
    }
    let legacyChain =
      allowingLegacyV8 && chainRelease.map { schemaObjects(database) == $0.objects } == true
    guard current || legacy || legacyChain else {
      throw CanonicalCommitError.incompatibleCanonicalStore
    }
  }

  private func insertMeta(_ database: OpaquePointer, key: String, value: String) throws {
    try run(
      database, sql: "INSERT INTO ledger_meta(key, value) VALUES(?, ?)",
      values: [.text(key), .text(value)])
  }

  private func insertProvenance(_ value: FieldProvenance, into database: OpaquePointer) throws {
    try run(
      database,
      sql: """
        INSERT OR IGNORE INTO provenance_reference(
          provenance_id, artifact_sha256, profile_id, adapter_version, container_member,
          source_table, source_record_key, source_column_ordinal, source_column_name
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      values: [
        .text(value.deterministicID), .text(value.artifactSHA256), .text(value.profileID),
        .text(value.adapterVersion), .optionalText(value.locator.containerMember),
        .text(value.locator.table), .text(value.locator.recordKey),
        .optionalInt(value.locator.columnOrdinal), .optionalText(value.locator.columnName),
      ])
    guard try provenanceMatches(value, database: database) else {
      throw CanonicalCommitError.idempotencyConflict
    }
  }

  private func insertEvent(_ event: CanonicalEconomicEvent, into database: OpaquePointer) throws {
    let zoneKind: String
    let zoneValue: String
    if let identifier = event.occurredAt.timeZone.ianaIdentifier {
      zoneKind = "iana"
      zoneValue = identifier
    } else if let offset = event.occurredAt.timeZone.fixedOffsetSeconds {
      zoneKind = "fixed"
      zoneValue = String(offset)
    } else {
      throw CanonicalCommitError.invalidRequest
    }
    try run(
      database,
      sql: """
        INSERT INTO economic_event(
          event_id, account_id, event_kind, amount_literal, currency_unit,
          instant_milliseconds, local_year, local_month, local_day, local_hour, local_minute,
          local_second, local_millisecond, timezone_kind, timezone_value,
          temporal_precision, resolved_offset_seconds, source_record_id, provenance_id
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      values: [
        .text(event.eventID), .text(event.accountID), .text(event.kind.rawValue),
        .text(event.amount.amount.rawLiteral), .text(event.amount.unitCode),
        .int64(event.occurredAt.instant.epochMilliseconds),
        .int(event.occurredAt.localDateTime.date.year),
        .int(event.occurredAt.localDateTime.date.month),
        .int(event.occurredAt.localDateTime.date.day), .int(event.occurredAt.localDateTime.hour),
        .int(event.occurredAt.localDateTime.minute), .int(event.occurredAt.localDateTime.second),
        .int(event.occurredAt.localDateTime.millisecond), .text(zoneKind), .text(zoneValue),
        .text(event.occurredAt.precision.rawValue), .int(event.occurredAt.resolvedOffsetSeconds),
        .text(event.sourceRecordID), .text(event.amountProvenance.deterministicID),
      ])
  }

  private func insertSourceBinding(
    _ binding: CanonicalEventSourceBinding, eventID: String, into database: OpaquePointer
  ) throws {
    try run(
      database,
      sql:
        "INSERT INTO event_source_binding(event_id, semantic, provenance_id, declared_type, storage_class) VALUES(?, ?, ?, ?, ?)",
      values: [
        .text(eventID), .text(binding.semantic.rawValue),
        .text(binding.provenance.deterministicID), .optionalText(binding.declaredType),
        .text(binding.storageClass.rawValue),
      ])
  }

  private func insertSidecar(
    _ sidecar: CanonicalPersistedSidecar, into database: OpaquePointer
  ) throws {
    try run(
      database,
      sql:
        "INSERT INTO sidecar_reference(sidecar_id, event_id, provenance_id, format_version, declared_type, storage_class, payload) VALUES(?, ?, ?, ?, ?, ?, ?)",
      values: [
        .text(sidecar.sidecarID), .text(sidecar.eventID),
        .text(sidecar.provenance.deterministicID), .int(sidecar.formatVersion),
        .optionalText(sidecar.declaredType), .text(sidecar.storageClass.rawValue),
        .blob(sidecar.payload),
      ])
  }

  private func insertReceiptOwnedAnchor(
    _ anchor: CanonicalReceiptOwnedAnchor, into database: OpaquePointer
  ) throws {
    try run(
      database,
      sql: """
        INSERT INTO receipt_preservation_anchor(
          anchor_id, idempotency_key, source_subject_id, subject_kind, artifact_sha256, profile_id,
          adapter_version, container_member, source_table, source_record_key
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      values: [
        .text(anchor.anchorID), .text(anchor.receiptID), .text(anchor.sourceSubjectID),
        .text(anchor.subjectKind.rawValue),
        .text(anchor.artifactSHA256), .text(anchor.profileID), .text(anchor.adapterVersion),
        .optionalText(anchor.containerMember), .text(anchor.sourceTable),
        .optionalText(anchor.sourceRecordKey),
      ])
  }

  private func insertReceiptOwnedPayload(
    _ payload: CanonicalReceiptOwnedPayload, into database: OpaquePointer
  ) throws {
    try run(
      database,
      sql: """
        INSERT INTO receipt_preservation_payload(
          payload_id, idempotency_key, anchor_id, source_subject_id, provenance_id, format_version,
          declared_type, storage_class, payload
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      values: [
        .text(payload.payloadID), .text(payload.receiptID), .text(payload.anchorID),
        .text(payload.sourceSubjectID),
        .text(payload.provenance.deterministicID), .int(payload.formatVersion),
        .optionalText(payload.declaredType), .text(payload.storageClass.rawValue),
        .blob(payload.payload),
      ])
  }

  private func insertReceipt(
    request: CanonicalCommitRequest, integrityHash: String, eventSetHash: String,
    into database: OpaquePointer
  ) throws {
    try run(
      database,
      sql: """
        INSERT INTO import_receipt(
          idempotency_key, staging_digest, artifact_sha256, profile_id, adapter_version,
          reconciliation_hash, event_set_hash, event_count, schema_version
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      values: [
        .text(request.expectedManifest.stagingID), .text(request.expectedStagingDigest),
        .text(request.expectedManifest.artifactSHA256), .text(request.expectedManifest.profileID),
        .text(request.expectedManifest.adapterVersion), .text(integrityHash), .text(eventSetHash),
        .int(request.events.count), .int(8),
      ])
  }

  private func insertReceiptMembership(
    request: CanonicalCommitRequest, plan: TrustedCommitPlan, into database: OpaquePointer
  ) throws {
    let receipt = request.expectedManifest.stagingID
    for event in request.events {
      try run(
        database, sql: "INSERT INTO receipt_event(idempotency_key, event_id) VALUES(?, ?)",
        values: [.text(receipt), .text(event.eventID)])
      for binding in event.sourceBindings {
        try run(
          database,
          sql:
            "INSERT INTO receipt_binding(idempotency_key, event_id, semantic, provenance_id) VALUES(?, ?, ?, ?)",
          values: [
            .text(receipt), .text(event.eventID), .text(binding.semantic.rawValue),
            .text(binding.provenance.deterministicID),
          ])
      }
      for sidecar in plan.sidecarsByEvent[event.eventID] ?? [] {
        try run(
          database,
          sql:
            "INSERT INTO receipt_sidecar(idempotency_key, sidecar_id, event_id, provenance_id) VALUES(?, ?, ?, ?)",
          values: [
            .text(receipt), .text(sidecar.sidecarID), .text(event.eventID),
            .text(sidecar.provenance.deterministicID),
          ])
      }
    }
    for anchor in plan.receiptOwnedAnchors {
      try run(
        database,
        sql: """
          INSERT INTO receipt_preservation_membership(
            idempotency_key, source_subject_id, subject_kind, anchor_id,
            anchor_subject_id, anchor_subject_kind, payload_id
          ) VALUES(?, ?, ?, ?, ?, ?, NULL)
          """,
        values: [
          .text(receipt), .text(anchor.sourceSubjectID), .text(anchor.subjectKind.rawValue),
          .text(anchor.anchorID), .text(anchor.sourceSubjectID),
          .text(anchor.subjectKind.rawValue),
        ])
    }
    let anchorsByID: [String: CanonicalReceiptOwnedAnchor] = Dictionary(
      uniqueKeysWithValues: plan.receiptOwnedAnchors.map { ($0.anchorID, $0) })
    for payload in plan.receiptOwnedPayloads {
      guard let anchor = anchorsByID[payload.anchorID] else {
        throw CanonicalCommitError.unsafeMapping
      }
      try run(
        database,
        sql: """
          INSERT INTO receipt_preservation_membership(
            idempotency_key, source_subject_id, subject_kind, anchor_id,
            anchor_subject_id, anchor_subject_kind, payload_id
          ) VALUES(?, ?, 'field', ?, ?, ?, ?)
          """,
        values: [
          .text(receipt), .text(payload.sourceSubjectID), .text(payload.anchorID),
          .text(anchor.sourceSubjectID), .text(anchor.subjectKind.rawValue),
          .text(payload.payloadID),
        ])
    }
  }

  private func insertObservedV19Commitments(
    request: CanonicalCommitRequest, plan: TrustedCommitPlan, into database: OpaquePointer
  ) throws {
    guard request.isObservedV19AdapterAuthorized else { return }
    let transactionIDs = transactionIDs(for: request)
    for event in request.events {
      // A paired transfer leg writes onto the shared transfer revision with leg-qualified
      // field names; every other event writes onto its own revision as before.
      let revisionID = try StableLedgerID.revision(
        transactionID: transactionIDs[event.eventID] ?? event.eventID, revision: 1)
      let base = MoneyManagerV19Vocabulary.commitmentOrdinalBase(kind: event.kind)
      let fieldIDs = plan.sidecarsByEvent[event.eventID, default: []].map(\.sidecarID)
      let commitments: [(String, String)] = [
        (
          MoneyManagerV19Vocabulary.temporalCommitmentField,
          MoneyManagerV19Vocabulary.temporalCommitment(event.occurredAt)
        ),
        (
          MoneyManagerV19Vocabulary.receiptGenerationField,
          MoneyManagerV19Vocabulary.currentReceiptGenerationLiteral
        ),
        (
          MoneyManagerV19Vocabulary.temporalAnchorField,
          MoneyManagerV19Vocabulary.temporalCommitment(event.occurredAt)
        ),
        (
          MoneyManagerV19Vocabulary.sourceSubjectSetField,
          MoneyManagerV19Vocabulary.sourceSubjectSetCommitment(
            sourceRecordID: event.sourceRecordID, fieldIDs: fieldIDs)
        ),
        (
          MoneyManagerV19Vocabulary.sourceTimeZoneField,
          MoneyManagerV19Vocabulary.sourceTimeZoneLiteral(
            request.observedV19SourceTimeZone ?? event.occurredAt.timeZone)
        ),
      ]
      for (offset, commitment) in commitments.enumerated() {
        try run(
          database,
          sql:
            "INSERT INTO ledger_transaction_source_literal(revision_id, ordinal, field, literal, provenance_id) VALUES(?, ?, ?, ?, NULL)",
          values: [
            .text(revisionID), .int(base + offset),
            .text(MoneyManagerV19Vocabulary.commitmentField(commitment.0, kind: event.kind)),
            .text(commitment.1),
          ])
      }
    }
  }

  private func checksum(_ database: OpaquePointer) throws -> String {
    do {
      return try LedgerStore.canonicalChecksum(database)
    } catch {
      throw CanonicalCommitError.canonicalReadFailed
    }
  }

  private func readReceipt(_ database: OpaquePointer, idempotencyKey: String) throws -> Receipt? {
    var statement: OpaquePointer?
    let sql =
      "SELECT staging_digest, artifact_sha256, profile_id, adapter_version, reconciliation_hash, event_set_hash, event_count FROM import_receipt WHERE idempotency_key=?"
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement, bind(.text(idempotencyKey), to: statement, at: 1)
    else { throw CanonicalCommitError.canonicalReadFailed }
    defer { sqlite3_finalize(statement) }
    let result = sqlite3_step(statement)
    if result == SQLITE_DONE { return nil }
    guard result == SQLITE_ROW,
      let stagingDigest = columnText(statement, 0),
      let artifactSHA256 = columnText(statement, 1),
      let profileID = columnText(statement, 2),
      let adapterVersion = columnText(statement, 3),
      let reconciliationHash = columnText(statement, 4),
      let eventSetHash = columnText(statement, 5)
    else { throw CanonicalCommitError.canonicalReadFailed }
    return Receipt(
      stagingDigest: stagingDigest, artifactSHA256: artifactSHA256, profileID: profileID,
      adapterVersion: adapterVersion, integrityHash: reconciliationHash,
      eventSetHash: eventSetHash, eventCount: Int(sqlite3_column_int64(statement, 6)))
  }

  private func existingCanonicalStateIsHealthy(_ database: OpaquePointer, trustKey: Data? = nil)
    throws -> Bool
  {
    guard
      queryHasNoRows(
        database,
        "SELECT 1 FROM economic_event WHERE length(event_id)<>64 OR event_id GLOB '*[^0-9a-f]*' OR length(account_id)<>64 OR account_id GLOB '*[^0-9a-f]*' OR length(source_record_id)<>64 OR source_record_id GLOB '*[^0-9a-f]*' OR length(provenance_id)<>64 OR provenance_id GLOB '*[^0-9a-f]*'"
      ),
      queryHasNoRows(
        database,
        "SELECT 1 FROM economic_event WHERE amount_literal IS NULL OR amount_literal='' OR amount_literal GLOB '*[^0-9.+-]*' OR amount_literal NOT GLOB '*[0-9]*' OR currency_unit IS NULL OR length(currency_unit)<1 OR length(currency_unit)>32 OR currency_unit GLOB '*[^A-Za-z0-9_-]*' OR event_kind NOT IN ('income','expense','transfer_debit','transfer_credit','adjustment','adjustment_debit')"
      ),
      queryHasNoRows(
        database,
        "SELECT 1 FROM economic_event_transfer t LEFT JOIN economic_event d ON d.event_id=t.debit_event_id LEFT JOIN economic_event c ON c.event_id=t.credit_event_id WHERE length(t.transfer_id)<>64 OR t.transfer_id GLOB '*[^0-9a-f]*' OR d.event_kind IS NOT 'transfer_debit' OR c.event_kind IS NOT 'transfer_credit' OR d.account_id=c.account_id"
      ),
      queryHasNoRows(
        database,
        "SELECT 1 FROM economic_event e WHERE e.event_kind IN ('transfer_debit','transfer_credit') AND NOT EXISTS (SELECT 1 FROM economic_event_transfer t WHERE t.debit_event_id=e.event_id OR t.credit_event_id=e.event_id)"
      ),
      queryHasNoRows(
        database,
        "SELECT 1 FROM import_receipt WHERE length(idempotency_key)<>64 OR idempotency_key GLOB '*[^0-9a-f]*' OR length(staging_digest)<>64 OR staging_digest GLOB '*[^0-9a-f]*' OR length(artifact_sha256)<>64 OR artifact_sha256 GLOB '*[^0-9a-f]*' OR length(reconciliation_hash)<>64 OR reconciliation_hash GLOB '*[^0-9a-f]*' OR length(event_set_hash)<>64 OR event_set_hash GLOB '*[^0-9a-f]*' OR event_count<0"
      ),
      queryHasNoRows(
        database,
        "SELECT 1 FROM import_receipt r WHERE r.event_count <> (SELECT count(*) FROM receipt_event e WHERE e.idempotency_key=r.idempotency_key)"
      ),
      // Coverage checks are set differences (EXCEPT), not correlated NOT EXISTS: the receipt
      // tables are keyed by idempotency_key first, so a per-row lookup scanned the whole table
      // and a real-size backup took minutes per check. Right-hand NULLs are filtered so the
      // answer matches NOT EXISTS exactly.
      queryHasNoRows(
        database,
        "SELECT event_id FROM economic_event EXCEPT SELECT event_id FROM receipt_event WHERE event_id IS NOT NULL"
      ),
      queryHasNoRows(
        database,
        "SELECT event_id, semantic, provenance_id FROM event_source_binding EXCEPT SELECT event_id, semantic, provenance_id FROM receipt_binding WHERE event_id IS NOT NULL AND semantic IS NOT NULL AND provenance_id IS NOT NULL"
      ),
      queryHasNoRows(
        database,
        "SELECT sidecar_id, event_id, provenance_id FROM sidecar_reference EXCEPT SELECT sidecar_id, event_id, provenance_id FROM receipt_sidecar WHERE sidecar_id IS NOT NULL AND event_id IS NOT NULL AND provenance_id IS NOT NULL"
      ),
      queryHasNoRows(
        database,
        "SELECT 1 FROM receipt_binding r WHERE NOT EXISTS (SELECT 1 FROM receipt_event e WHERE e.idempotency_key=r.idempotency_key AND e.event_id=r.event_id)"
      ),
      queryHasNoRows(
        database,
        "SELECT 1 FROM receipt_sidecar r WHERE NOT EXISTS (SELECT 1 FROM receipt_event e WHERE e.idempotency_key=r.idempotency_key AND e.event_id=r.event_id)"
      ),
      queryHasNoRows(
        database,
        "SELECT event_id FROM receipt_event GROUP BY event_id HAVING count(*) <> 1"
      ),
      queryHasNoRows(
        database,
        "SELECT 1 FROM import_receipt r WHERE r.event_count=0 AND NOT EXISTS (SELECT 1 FROM receipt_preservation_membership m WHERE m.idempotency_key=r.idempotency_key)"
      ),
      queryHasNoRows(
        database,
        "SELECT 1 FROM receipt_preservation_anchor WHERE length(anchor_id)<>64 OR anchor_id GLOB '*[^0-9a-f]*' OR length(source_subject_id)<>64 OR source_subject_id GLOB '*[^0-9a-f]*' OR length(artifact_sha256)<>64 OR artifact_sha256 GLOB '*[^0-9a-f]*'"
      ),
      queryHasNoRows(
        database,
        "SELECT 1 FROM receipt_preservation_payload WHERE length(payload_id)<>64 OR payload_id GLOB '*[^0-9a-f]*' OR length(anchor_id)<>64 OR anchor_id GLOB '*[^0-9a-f]*' OR length(source_subject_id)<>64 OR source_subject_id GLOB '*[^0-9a-f]*' OR length(provenance_id)<>64 OR provenance_id GLOB '*[^0-9a-f]*'"
      ),
      queryHasNoRows(
        database,
        "SELECT 1 FROM sidecar_reference WHERE provenance_id<>sidecar_id OR format_version<>1 OR storage_class NOT IN ('null','integer','real','blob','text') OR length(coalesce(declared_type,''))>1024 OR length(payload)>\(CanonicalCommitDigest.maximumSidecarBytes) OR (storage_class='null' AND length(payload)<>0) OR (storage_class IN ('integer','real') AND length(payload)<>8)"
      ),
      queryHasNoRows(
        database,
        "SELECT 1 FROM receipt_preservation_payload WHERE provenance_id<>source_subject_id OR format_version<>1 OR storage_class NOT IN ('null','integer','real','blob','text') OR length(coalesce(declared_type,''))>1024 OR length(payload)>\(CanonicalCommitDigest.maximumSidecarBytes) OR (storage_class='null' AND length(payload)<>0) OR (storage_class IN ('integer','real') AND length(payload)<>8)"
      ),
      queryHasNoRows(
        database,
        "SELECT 1 WHERE (SELECT coalesce(sum(length(payload)),0) FROM sidecar_reference) + (SELECT coalesce(sum(length(payload)),0) FROM receipt_preservation_payload) > \(CanonicalCommitDigest.maximumTotalSidecarBytes)"
      ),
      queryHasNoRows(
        database,
        "SELECT 1 FROM receipt_preservation_membership m LEFT JOIN receipt_preservation_anchor a ON a.idempotency_key=m.idempotency_key AND a.anchor_id=m.anchor_id AND a.source_subject_id=m.anchor_subject_id AND a.subject_kind=m.anchor_subject_kind LEFT JOIN receipt_preservation_payload x ON x.idempotency_key=m.idempotency_key AND x.anchor_id=m.anchor_id AND x.payload_id=m.payload_id AND x.source_subject_id=m.source_subject_id WHERE a.anchor_id IS NULL OR m.subject_kind NOT IN ('table','record','field') OR (m.subject_kind IN ('table','record') AND (m.payload_id IS NOT NULL OR m.source_subject_id<>m.anchor_subject_id OR m.subject_kind<>m.anchor_subject_kind)) OR (m.subject_kind='field' AND (m.payload_id IS NULL OR x.payload_id IS NULL OR m.source_subject_id=m.anchor_subject_id OR m.anchor_subject_kind<>'record'))"
      ),
      queryHasNoRows(
        database,
        "SELECT 1 FROM receipt_preservation_anchor a LEFT JOIN import_receipt r ON r.idempotency_key=a.idempotency_key WHERE r.idempotency_key IS NULL OR a.artifact_sha256<>r.artifact_sha256 OR a.profile_id<>r.profile_id OR a.adapter_version<>r.adapter_version"
      ),
      queryHasNoRows(
        database,
        "SELECT 1 FROM receipt_preservation_payload x LEFT JOIN receipt_preservation_anchor a ON a.idempotency_key=x.idempotency_key AND a.anchor_id=x.anchor_id WHERE a.anchor_id IS NULL"
      ),
      queryHasNoRows(
        database,
        "SELECT 1 FROM receipt_preservation_payload x JOIN receipt_preservation_anchor a ON a.idempotency_key=x.idempotency_key AND a.anchor_id=x.anchor_id JOIN provenance_reference p ON p.provenance_id=x.provenance_id WHERE x.provenance_id<>x.source_subject_id OR a.subject_kind<>'record' OR p.artifact_sha256<>a.artifact_sha256 OR p.profile_id<>a.profile_id OR p.adapter_version<>a.adapter_version OR p.source_table<>a.source_table OR p.source_record_key<>a.source_record_key"
      ),
      queryHasNoRows(
        database,
        "SELECT 1 FROM receipt_sidecar r JOIN import_receipt i ON i.idempotency_key=r.idempotency_key JOIN sidecar_reference s ON s.sidecar_id=r.sidecar_id AND s.event_id=r.event_id AND s.provenance_id=r.provenance_id JOIN provenance_reference p ON p.provenance_id=s.provenance_id WHERE s.provenance_id<>s.sidecar_id OR p.artifact_sha256<>i.artifact_sha256 OR p.profile_id<>i.profile_id OR p.adapter_version<>i.adapter_version"
      ),
      queryHasNoRows(
        database,
        "SELECT a.anchor_id FROM receipt_preservation_anchor a LEFT JOIN receipt_preservation_membership m ON m.idempotency_key=a.idempotency_key AND m.anchor_id=a.anchor_id AND m.source_subject_id=a.source_subject_id AND m.payload_id IS NULL GROUP BY a.anchor_id HAVING count(m.idempotency_key)<>1"
      ),
      queryHasNoRows(
        database,
        "SELECT x.payload_id FROM receipt_preservation_payload x LEFT JOIN receipt_preservation_membership m ON m.idempotency_key=x.idempotency_key AND m.payload_id=x.payload_id AND m.source_subject_id=x.source_subject_id GROUP BY x.payload_id HAVING count(m.idempotency_key)<>1"
      ),
      queryHasNoRows(
        database,
        "SELECT provenance_id FROM provenance_reference EXCEPT SELECT provenance_id FROM event_source_binding WHERE provenance_id IS NOT NULL EXCEPT SELECT provenance_id FROM sidecar_reference WHERE provenance_id IS NOT NULL EXCEPT SELECT provenance_id FROM receipt_preservation_payload WHERE provenance_id IS NOT NULL"
      ),
      // CanonicalLedgerHealth owns persisted digest recomputation. Retain this importer-only
      // semantic replay until those typed receipt models are shared without a dependency cycle.
      try allReceiptsAreHealthy(database),
      try canonicalEventsAreHealthy(database),
      CanonicalLedgerHealth.isHealthy(database, trustKey: trustKey)
    else { return false }
    return true
  }

  private func allReceiptsAreHealthy(_ database: OpaquePointer) throws -> Bool {
    do {
      return try allReceiptsAreHealthyUnchecked(database)
    } catch CanonicalCommitError.canonicalReadFailed {
      return false
    }
  }

  private func allReceiptsAreHealthyUnchecked(_ database: OpaquePointer) throws -> Bool {
    var statement: OpaquePointer?
    let sql =
      "SELECT idempotency_key, event_set_hash, reconciliation_hash, event_count FROM import_receipt ORDER BY idempotency_key"
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw CanonicalCommitError.canonicalReadFailed }
    defer { sqlite3_finalize(statement) }
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { return true }
      guard result == SQLITE_ROW,
        let receipt = columnText(statement, 0), CanonicalIdentifier.isValid(receipt),
        let storedHash = columnText(statement, 1), CanonicalIdentifier.isValid(storedHash),
        let storedIntegrityHash = columnText(statement, 2),
        CanonicalIdentifier.isValid(storedIntegrityHash),
        sqlite3_column_type(statement, 3) == SQLITE_INTEGER,
        sqlite3_column_int64(statement, 3) >= 0,
        try countRows(
          database, sql: "SELECT count(*) FROM receipt_event WHERE idempotency_key=?",
          values: [.text(receipt)]) == Int(sqlite3_column_int64(statement, 3)),
        try
          (sqlite3_column_int64(statement, 3) > 0
          || countRows(
            database,
            sql: "SELECT count(*) FROM receipt_preservation_membership WHERE idempotency_key=?",
            values: [.text(receipt)]) > 0),
        try canonicalEventSetHash(database, receipt: receipt) == storedHash,
        try canonicalReceiptIntegrityHash(database, receipt: receipt) == storedIntegrityHash
      else { return false }
    }
  }

  private func canonicalReceiptIntegrityHash(
    _ database: OpaquePointer, receipt: String
  ) throws -> String {
    var statement: OpaquePointer?
    let sql = """
      SELECT idempotency_key, staging_digest, artifact_sha256, profile_id,
             adapter_version, event_set_hash, event_count, schema_version
      FROM import_receipt WHERE idempotency_key=?
      """
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement, bind(.text(receipt), to: statement, at: 1)
    else { throw CanonicalCommitError.canonicalReadFailed }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
      let idempotencyKey = columnText(statement, 0),
      let stagingDigest = columnText(statement, 1),
      let artifactSHA256 = columnText(statement, 2),
      let profileID = columnText(statement, 3),
      let adapterVersion = columnText(statement, 4),
      let eventSetHash = columnText(statement, 5),
      sqlite3_column_type(statement, 6) == SQLITE_INTEGER,
      sqlite3_column_type(statement, 7) == SQLITE_INTEGER
    else { throw CanonicalCommitError.canonicalReadFailed }
    let eventCount = String(sqlite3_column_int64(statement, 6))
    let schemaVersion = String(sqlite3_column_int64(statement, 7))
    let canonicalEvents = try canonicalEventSetHash(database, receipt: receipt)
    let canonicalPreservation = try canonicalPreservationSetHash(database, receipt: receipt)
    let envelope = [
      idempotencyKey, stagingDigest, artifactSHA256, profileID, adapterVersion, eventSetHash,
      eventCount, schemaVersion,
    ]
    guard MoneyManagerV19Vocabulary.admittedProfileIDs.contains(profileID) else {
      return MoneyManagerV19Vocabulary.receiptIntegrityHash(
        envelope: envelope, eventSetHash: canonicalEvents, preservationHash: canonicalPreservation,
        generation: .legacy)
    }
    let generation = try persistedV19ReceiptGeneration(database, receipt: receipt)
    return MoneyManagerV19Vocabulary.receiptIntegrityHash(
      envelope: envelope, eventSetHash: canonicalEvents, preservationHash: canonicalPreservation,
      generation: generation)
  }

  private func persistedV19ReceiptGeneration(
    _ database: OpaquePointer, receipt: String
  ) throws -> MoneyManagerV19Vocabulary.ReceiptGeneration {
    // Ledgers older than v12 have no transfer table and no paired legs.
    let transactionOfEvent =
      scalarText(
        database,
        "SELECT name FROM sqlite_master WHERE type='table' AND name='economic_event_transfer'"
      ) == nil
      ? "r.event_id"
      : "COALESCE((SELECT t.transfer_id FROM economic_event_transfer t WHERE t.debit_event_id=r.event_id OR t.credit_event_id=r.event_id), r.event_id)"
    let current =
      scalarText(
        database,
        "SELECT 1 FROM ledger_transaction_source_literal l JOIN ledger_transaction_revision v ON v.revision_id=l.revision_id JOIN receipt_event r ON v.transaction_id=\(transactionOfEvent) WHERE r.idempotency_key='\(receipt)' AND l.field IN ('\(MoneyManagerV19Vocabulary.receiptGenerationField)', '\(MoneyManagerV19Vocabulary.receiptGenerationField).debit', '\(MoneyManagerV19Vocabulary.receiptGenerationField).credit') AND l.literal='\(MoneyManagerV19Vocabulary.currentReceiptGenerationLiteral)' LIMIT 1"
      ) != nil
    let legacy =
      scalarText(
        database,
        "SELECT 1 FROM ledger_transaction_source_literal l JOIN ledger_transaction_revision v ON v.revision_id=l.revision_id JOIN receipt_event r ON v.transaction_id=\(transactionOfEvent) WHERE r.idempotency_key='\(receipt)' AND l.field IN ('\(MoneyManagerV19Vocabulary.receiptGenerationField)', '\(MoneyManagerV19Vocabulary.receiptGenerationField).debit', '\(MoneyManagerV19Vocabulary.receiptGenerationField).credit') AND l.literal='\(MoneyManagerV19Vocabulary.legacyReceiptGenerationLiteral)' LIMIT 1"
      ) != nil
    guard !(current && legacy) else { throw CanonicalCommitError.canonicalReadFailed }
    return current || !legacy ? .current : .legacy
  }

  private func canonicalPreservationSetHash(
    _ database: OpaquePointer, receipt: String
  ) throws -> String {
    let preservation = try readReceiptOwnedPreservation(database, receipt: receipt)
    var components = ["ledger-atlas/receipt-owned-preservation-set/v4"]
    var membershipStatement: OpaquePointer?
    let membershipSQL = """
      SELECT idempotency_key, source_subject_id, subject_kind, anchor_id, anchor_subject_id,
             anchor_subject_kind, payload_id
      FROM receipt_preservation_membership
      WHERE idempotency_key=? ORDER BY source_subject_id
      """
    guard sqlite3_prepare_v2(database, membershipSQL, -1, &membershipStatement, nil) == SQLITE_OK,
      let membershipStatement, bind(.text(receipt), to: membershipStatement, at: 1)
    else { throw CanonicalCommitError.canonicalReadFailed }
    defer { sqlite3_finalize(membershipStatement) }
    while true {
      let result = sqlite3_step(membershipStatement)
      if result == SQLITE_DONE { break }
      guard result == SQLITE_ROW, columnText(membershipStatement, 0) == receipt,
        let subject = columnText(membershipStatement, 1),
        let kind = columnText(membershipStatement, 2),
        let anchor = columnText(membershipStatement, 3),
        let anchorSubject = columnText(membershipStatement, 4),
        let anchorKind = columnText(membershipStatement, 5)
      else { throw CanonicalCommitError.canonicalReadFailed }
      components.append(contentsOf: [receipt, subject, kind, anchor, anchorSubject, anchorKind])
      components.append(
        contentsOf: CanonicalCommitDigest.optionalComponents(
          columnOptionalText(membershipStatement, 6)))
    }
    for anchor in preservation.anchors {
      components.append(contentsOf: [
        anchor.anchorID, anchor.receiptID, anchor.sourceSubjectID, anchor.subjectKind.rawValue,
        anchor.artifactSHA256, anchor.profileID, anchor.adapterVersion,
      ])
      components.append(
        contentsOf: CanonicalCommitDigest.optionalComponents(anchor.containerMember))
      components.append(anchor.sourceTable)
      components.append(
        contentsOf: CanonicalCommitDigest.optionalComponents(anchor.sourceRecordKey))
    }
    for payload in preservation.payloads {
      let locator = payload.provenance.locator
      let payloadHash = CanonicalReceiptDigest.hex(SHA256.hash(data: payload.payload))
      components.append(contentsOf: [
        payload.payloadID, payload.receiptID, payload.anchorID, payload.sourceSubjectID,
        String(payload.formatVersion),
      ])
      components.append(contentsOf: CanonicalCommitDigest.optionalComponents(payload.declaredType))
      components.append(contentsOf: [
        payload.storageClass.rawValue, payloadHash,
        payload.provenance.artifactSHA256, payload.provenance.profileID,
        payload.provenance.adapterVersion,
      ])
      components.append(
        contentsOf: CanonicalCommitDigest.optionalComponents(locator.containerMember))
      components.append(contentsOf: [locator.table, locator.recordKey])
      components.append(
        contentsOf: CanonicalCommitDigest.optionalComponents(
          locator.columnOrdinal.map(String.init)))
      components.append(contentsOf: CanonicalCommitDigest.optionalComponents(locator.columnName))
      components.append(payload.provenance.deterministicID)
    }
    return CanonicalCommitDigest.hash(components)
  }

  private func canonicalEventSetHash(_ database: OpaquePointer, receipt: String) throws -> String {
    var components = [CanonicalCommitDigest.eventSetPrefix]
    var statement: OpaquePointer?
    let sql = """
      SELECT e.event_id, e.account_id, e.event_kind, e.amount_literal, e.currency_unit,
             e.instant_milliseconds, e.local_year, e.local_month, e.local_day,
             e.local_hour, e.local_minute, e.local_second, e.local_millisecond,
             e.timezone_kind, e.timezone_value, e.temporal_precision,
             e.resolved_offset_seconds, e.source_record_id, e.provenance_id
      FROM receipt_event r JOIN economic_event e ON e.event_id=r.event_id
      WHERE r.idempotency_key=? ORDER BY e.event_id
      """
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement, bind(.text(receipt), to: statement, at: 1)
    else { throw CanonicalCommitError.canonicalReadFailed }
    defer { sqlite3_finalize(statement) }
    var eventCount = 0
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE {
        return CanonicalCommitDigest.hash(components)
      }
      guard result == SQLITE_ROW else { throw CanonicalCommitError.canonicalReadFailed }
      guard let eventID = columnText(statement, 0), let accountID = columnText(statement, 1),
        let kind = columnText(statement, 2), let amount = columnText(statement, 3),
        let currency = columnText(statement, 4), let zoneKind = columnText(statement, 13),
        let zoneValue = columnText(statement, 14), let precision = columnText(statement, 15),
        let sourceRecordID = columnText(statement, 17),
        let provenanceID = columnText(statement, 18)
      else { throw CanonicalCommitError.canonicalReadFailed }
      let dateAndTime = (5...12).map { String(sqlite3_column_int64(statement, Int32($0))) }
      components.append(
        contentsOf: [
          eventID, accountID, kind, amount, currency,
        ] + dateAndTime + [
          zoneKind, zoneValue, precision, String(sqlite3_column_int64(statement, 16)),
          sourceRecordID, provenanceID,
        ])
      try appendEventSetBindings(
        database, eventID: eventID, into: &components)
      try appendEventSetSidecars(
        database, eventID: eventID, into: &components)
      eventCount += 1
    }
  }

  private func appendEventSetBindings(
    _ database: OpaquePointer, eventID: String, into components: inout [String]
  ) throws {
    var statement: OpaquePointer?
    let sql =
      "SELECT semantic, provenance_id, declared_type, storage_class FROM event_source_binding WHERE event_id=? ORDER BY semantic"
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement, bind(.text(eventID), to: statement, at: 1)
    else { throw CanonicalCommitError.canonicalReadFailed }
    defer { sqlite3_finalize(statement) }
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { return }
      guard result == SQLITE_ROW, let semantic = columnText(statement, 0),
        let provenance = columnText(statement, 1), let storage = columnText(statement, 3)
      else { throw CanonicalCommitError.canonicalReadFailed }
      components.append(contentsOf: [semantic, provenance])
      components.append(
        contentsOf: CanonicalCommitDigest.optionalComponents(columnOptionalText(statement, 2)))
      components.append(storage)
    }
  }

  private func appendEventSetSidecars(
    _ database: OpaquePointer, eventID: String, into components: inout [String]
  ) throws {
    var statement: OpaquePointer?
    let sql = """
      SELECT s.sidecar_id, s.provenance_id, s.format_version, s.declared_type,
             s.storage_class, s.payload, p.artifact_sha256, p.profile_id,
             p.adapter_version, p.container_member, p.source_table,
             p.source_record_key, p.source_column_ordinal, p.source_column_name
      FROM sidecar_reference s
      JOIN provenance_reference p ON p.provenance_id=s.provenance_id
      WHERE s.event_id=? ORDER BY s.sidecar_id
      """
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement, bind(.text(eventID), to: statement, at: 1)
    else { throw CanonicalCommitError.canonicalReadFailed }
    defer { sqlite3_finalize(statement) }
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { return }
      guard result == SQLITE_ROW, let sidecarID = columnText(statement, 0),
        let provenanceID = columnText(statement, 1),
        sqlite3_column_type(statement, 2) == SQLITE_INTEGER,
        let storageLiteral = columnText(statement, 4),
        let storageClass = CanonicalFieldStorageClass(rawValue: storageLiteral),
        let payload = columnBlob(statement, 5), let artifact = columnText(statement, 6),
        let profile = columnText(statement, 7), let adapter = columnText(statement, 8),
        let table = columnText(statement, 10), let recordKey = columnText(statement, 11)
      else { throw CanonicalCommitError.canonicalReadFailed }
      let provenance = FieldProvenance(
        artifactSHA256: artifact, profileID: profile, adapterVersion: adapter,
        locator: SourceLocator(
          containerMember: columnOptionalText(statement, 9), table: table,
          recordKey: recordKey, columnOrdinal: columnOptionalInt(statement, 12),
          columnName: columnOptionalText(statement, 13)), deterministicID: provenanceID)
      do {
        let sidecar = try CanonicalPersistedSidecar(
          sidecarID: sidecarID, eventID: eventID,
          formatVersion: Int(sqlite3_column_int64(statement, 2)),
          declaredType: columnOptionalText(statement, 3), storageClass: storageClass,
          payload: payload, provenance: provenance,
          maximumBytes: CanonicalCommitDigest.maximumSidecarBytes)
        components.append(contentsOf: CanonicalCommitDigest.sidecarComponents(sidecar))
      } catch { throw CanonicalCommitError.canonicalReadFailed }
    }
  }

  private func canonicalEventsAreHealthy(_ database: OpaquePointer) throws -> Bool {
    let sql = """
      SELECT event_id, account_id, event_kind, amount_literal, currency_unit,
             instant_milliseconds, local_year, local_month, local_day,
             local_hour, local_minute, local_second, local_millisecond,
             timezone_kind, timezone_value, temporal_precision,
             resolved_offset_seconds, source_record_id, provenance_id
      FROM economic_event ORDER BY event_id
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw CanonicalCommitError.canonicalReadFailed }
    defer { sqlite3_finalize(statement) }
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { return true }
      guard result == SQLITE_ROW,
        let eventID = columnText(statement, 0), CanonicalIdentifier.isValid(eventID),
        let accountID = columnText(statement, 1), CanonicalIdentifier.isValid(accountID),
        let eventKind = columnText(statement, 2),
        CanonicalEventKind(rawValue: eventKind) != nil,
        let amountLiteral = columnText(statement, 3),
        let amount = try? ExactDecimal(amountLiteral),
        let currencyUnit = columnText(statement, 4),
        (try? CurrencyAmount(unitCode: currencyUnit, amount: amount)) != nil,
        let sourceRecordID = columnText(statement, 17),
        CanonicalIdentifier.isValid(sourceRecordID),
        let provenanceID = columnText(statement, 18),
        CanonicalIdentifier.isValid(provenanceID)
      else { return false }
      let zoneKind = columnText(statement, 13)
      guard let zoneValue = columnText(statement, 14), !zoneValue.isEmpty,
        let precision = SourceTemporalPrecision(rawValue: columnText(statement, 15) ?? ""),
        let date = try? SourceLocalDate(
          year: Int(sqlite3_column_int64(statement, 6)),
          month: Int(sqlite3_column_int64(statement, 7)),
          day: Int(sqlite3_column_int64(statement, 8))),
        let localDateTime = try? SourceLocalDateTime(
          date: date,
          hour: Int(sqlite3_column_int64(statement, 9)),
          minute: Int(sqlite3_column_int64(statement, 10)),
          second: Int(sqlite3_column_int64(statement, 11)),
          millisecond: Int(sqlite3_column_int64(statement, 12))),
        let resolvedOffset = Int(exactly: sqlite3_column_int64(statement, 16))
      else { return false }
      switch zoneKind {
      case "fixed":
        guard let fixedOffset = Int(zoneValue),
          let fixed = try? SourceTimeZone(fixedOffsetSeconds: fixedOffset)
        else { return false }
        guard
          (try? SourceTemporal(
            instant: UTCInstant(epochMilliseconds: sqlite3_column_int64(statement, 5)),
            localDateTime: localDateTime, timeZone: fixed, precision: precision,
            resolvedOffsetSeconds: resolvedOffset)) != nil
        else { return false }
      case "iana":
        // An existing ledger is historical evidence. Its IANA label may have disappeared
        // from a later OS tzdata release, but its persisted resolved offset remains enough
        // to validate the recorded local/UTC relationship. New writes still construct
        // SourceTemporal with SourceTimeZone(ianaIdentifier:), so this does not admit an
        // unknown identifier into a newly-created event.
        guard isPlausiblePersistedIANAIdentifier(zoneValue),
          (try? SourceTemporal.validatingPersistedIANA(
            instant: UTCInstant(epochMilliseconds: sqlite3_column_int64(statement, 5)),
            localDateTime: localDateTime, identifier: zoneValue, precision: precision,
            resolvedOffsetSeconds: resolvedOffset)) != nil
        else { return false }
      default:
        return false
      }
    }
  }

  private func isPlausiblePersistedIANAIdentifier(_ identifier: String) -> Bool {
    let bytes = Array(identifier.utf8)
    guard !bytes.isEmpty, bytes.count <= 255, !identifier.contains("\0") else { return false }
    return bytes.allSatisfy { byte in
      (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
        || byte == 47 || byte == 95 || byte == 45 || byte == 43
    }
  }

  /// A matching receipt only proves a prior transaction if every state row it names still
  /// agrees with the authenticated retry request. This makes a damaged ledger fail closed
  /// instead of reporting a false unchanged result.
  private func receiptBackedStateMatches(
    request: CanonicalCommitRequest, plan: TrustedCommitPlan, database: OpaquePointer
  ) throws -> Bool {
    let receipt = request.expectedManifest.stagingID
    // Validate every receipt envelope before trusting the requested one. A syntactically valid
    // orphan receipt must not make an unchanged retry report a checksum over tampered state.
    guard
      queryHasNoRows(
        database,
        """
        SELECT 1 FROM import_receipt r
        WHERE r.event_count < 0
           OR r.event_count != (
             SELECT count(*) FROM receipt_event e WHERE e.idempotency_key=r.idempotency_key
           )
           OR (r.event_count = 0 AND NOT EXISTS (
             SELECT 1 FROM receipt_preservation_membership m
             WHERE m.idempotency_key=r.idempotency_key
           ))
        """
      )
    else { return false }
    let expectedBindingCount = request.events.reduce(0) { $0 + $1.sourceBindings.count }
    let expectedSidecarCount = request.events.reduce(0) {
      $0 + (plan.sidecarsByEvent[$1.eventID] ?? []).count
    }
    let expectedPreservationCount =
      plan.receiptOwnedAnchors.count + plan.receiptOwnedPayloads.count
    guard
      try countRows(
        database, sql: "SELECT count(*) FROM receipt_event WHERE idempotency_key=?",
        values: [.text(receipt)]) == request.events.count,
      try countRows(
        database, sql: "SELECT count(*) FROM receipt_binding WHERE idempotency_key=?",
        values: [.text(receipt)]) == expectedBindingCount,
      try countRows(
        database, sql: "SELECT count(*) FROM receipt_sidecar WHERE idempotency_key=?",
        values: [.text(receipt)]) == expectedSidecarCount,
      try countRows(
        database,
        sql: "SELECT count(*) FROM receipt_preservation_membership WHERE idempotency_key=?",
        values: [.text(receipt)]) == expectedPreservationCount,
      try readReceiptOwnedPreservation(database, receipt: receipt)
        == CanonicalReceiptOwnedPreservation(
          anchors: plan.receiptOwnedAnchors, payloads: plan.receiptOwnedPayloads)
    else {
      return false
    }
    guard try transferPairsMatch(request, database: database) else { return false }
    for event in request.events {
      guard
        try countRows(
          database,
          sql: "SELECT count(*) FROM receipt_event WHERE idempotency_key=? AND event_id=?",
          values: [.text(receipt), .text(event.eventID)]) == 1,
        try eventMatches(event, database: database),
        scalarInt(
          database,
          "SELECT count(*) FROM event_source_binding WHERE event_id='\(event.eventID)'"
        ) == event.sourceBindings.count
      else { return false }
      for binding in event.sourceBindings {
        guard
          try countRows(
            database,
            sql:
              "SELECT count(*) FROM receipt_binding WHERE idempotency_key=? AND event_id=? AND semantic=? AND provenance_id=?",
            values: [
              .text(receipt), .text(event.eventID), .text(binding.semantic.rawValue),
              .text(binding.provenance.deterministicID),
            ]) == 1,
          try bindingMatches(binding, eventID: event.eventID, database: database),
          try provenanceMatches(binding.provenance, database: database)
        else { return false }
      }
      let expectedSidecars = (plan.sidecarsByEvent[event.eventID] ?? []).sorted {
        $0.sidecarID < $1.sidecarID
      }
      let persistedSidecars = try readSidecars(database, eventID: event.eventID)
      guard persistedSidecars == expectedSidecars else { return false }
      for sidecar in expectedSidecars {
        guard
          try countRows(
            database,
            sql:
              "SELECT count(*) FROM receipt_sidecar WHERE idempotency_key=? AND sidecar_id=? AND event_id=? AND provenance_id=?",
            values: [
              .text(receipt), .text(sidecar.sidecarID), .text(event.eventID),
              .text(sidecar.provenance.deterministicID),
            ]) == 1,
          try provenanceMatches(sidecar.provenance, database: database)
        else { return false }
      }
    }
    guard
      queryHasNoRows(
        database,
        "SELECT event_id FROM economic_event EXCEPT SELECT event_id FROM receipt_event WHERE event_id IS NOT NULL"
      ),
      queryHasNoRows(
        database,
        "SELECT event_id, semantic, provenance_id FROM event_source_binding EXCEPT SELECT event_id, semantic, provenance_id FROM receipt_binding WHERE event_id IS NOT NULL AND semantic IS NOT NULL AND provenance_id IS NOT NULL"
      ),
      queryHasNoRows(
        database,
        "SELECT sidecar_id, event_id, provenance_id FROM sidecar_reference EXCEPT SELECT sidecar_id, event_id, provenance_id FROM receipt_sidecar WHERE sidecar_id IS NOT NULL AND event_id IS NOT NULL AND provenance_id IS NOT NULL"
      ),
      queryHasNoRows(
        database,
        "SELECT anchor_id, source_subject_id FROM receipt_preservation_anchor EXCEPT SELECT anchor_id, source_subject_id FROM receipt_preservation_membership WHERE payload_id IS NULL AND anchor_id IS NOT NULL AND source_subject_id IS NOT NULL"
      ),
      queryHasNoRows(
        database,
        "SELECT payload_id, source_subject_id FROM receipt_preservation_payload EXCEPT SELECT payload_id, source_subject_id FROM receipt_preservation_membership WHERE payload_id IS NOT NULL AND source_subject_id IS NOT NULL"
      ),
      queryHasNoRows(
        database,
        "SELECT provenance_id FROM provenance_reference EXCEPT SELECT provenance_id FROM event_source_binding WHERE provenance_id IS NOT NULL EXCEPT SELECT provenance_id FROM sidecar_reference WHERE provenance_id IS NOT NULL EXCEPT SELECT provenance_id FROM receipt_preservation_payload WHERE provenance_id IS NOT NULL"
      )
    else { return false }
    // Checksum computation is deliberately included in retry validation: any malformed
    // canonical value is rejected rather than being hidden behind the receipt fast path.
    return !(try checksum(database)).isEmpty
  }

  /// The persisted pairs that touch this receipt's events are exactly the requested pairs.
  private func transferPairsMatch(_ request: CanonicalCommitRequest, database: OpaquePointer)
    throws -> Bool
  {
    let receipt = request.expectedManifest.stagingID
    guard CanonicalIdentifier.isValid(receipt) else { return false }
    var persisted: [[String]] = []
    try readRows(
      database,
      sql: """
        SELECT t.transfer_id, t.debit_event_id, t.credit_event_id FROM economic_event_transfer t
        WHERE EXISTS (SELECT 1 FROM receipt_event r WHERE r.idempotency_key='\(receipt)'
          AND (r.event_id=t.debit_event_id OR r.event_id=t.credit_event_id))
        ORDER BY t.transfer_id
        """
    ) { statement in
      persisted.append([
        columnText(statement, 0) ?? "", columnText(statement, 1) ?? "",
        columnText(statement, 2) ?? "",
      ])
    }
    let expected = request.transferPairs.sorted { $0.transferID < $1.transferID }.map {
      [$0.transferID, $0.debitEventID, $0.creditEventID]
    }
    return persisted == expected
  }

  private func eventMatches(_ event: CanonicalEconomicEvent, database: OpaquePointer) throws -> Bool
  {
    var statement: OpaquePointer?
    let sql = """
      SELECT account_id, event_kind, amount_literal, currency_unit, instant_milliseconds,
        local_year, local_month, local_day, local_hour, local_minute, local_second,
        local_millisecond, timezone_kind, timezone_value, temporal_precision,
        resolved_offset_seconds, source_record_id, provenance_id
      FROM economic_event WHERE event_id=?
      """
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement, bind(.text(event.eventID), to: statement, at: 1)
    else { throw CanonicalCommitError.canonicalReadFailed }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return false }
    let zoneKind = event.occurredAt.timeZone.ianaIdentifier == nil ? "fixed" : "iana"
    let zoneValue =
      event.occurredAt.timeZone.ianaIdentifier
      ?? String(event.occurredAt.timeZone.fixedOffsetSeconds ?? Int.min)
    let date = event.occurredAt.localDateTime.date
    return columnText(statement, 0) == event.accountID
      && columnText(statement, 1) == event.kind.rawValue
      && columnText(statement, 2) == event.amount.amount.rawLiteral
      && columnText(statement, 3) == event.amount.unitCode
      && sqlite3_column_int64(statement, 4) == event.occurredAt.instant.epochMilliseconds
      && Int(sqlite3_column_int64(statement, 5)) == date.year
      && Int(sqlite3_column_int64(statement, 6)) == date.month
      && Int(sqlite3_column_int64(statement, 7)) == date.day
      && Int(sqlite3_column_int64(statement, 8)) == event.occurredAt.localDateTime.hour
      && Int(sqlite3_column_int64(statement, 9)) == event.occurredAt.localDateTime.minute
      && Int(sqlite3_column_int64(statement, 10)) == event.occurredAt.localDateTime.second
      && Int(sqlite3_column_int64(statement, 11)) == event.occurredAt.localDateTime.millisecond
      && columnText(statement, 12) == zoneKind && columnText(statement, 13) == zoneValue
      && columnText(statement, 14) == event.occurredAt.precision.rawValue
      && Int(sqlite3_column_int64(statement, 15)) == event.occurredAt.resolvedOffsetSeconds
      && columnText(statement, 16) == event.sourceRecordID
      && columnText(statement, 17) == event.amountProvenance.deterministicID
  }

  private func sourceIdentityAlreadyBound(
    _ event: CanonicalEconomicEvent, plan: TrustedCommitPlan, database: OpaquePointer
  ) throws -> Bool {
    // Stable source uid detection belongs at this boundary.
    if let sidecars = plan.sidecarsByEvent[event.eventID],
      let uid = sidecars.first(where: { sidecar in
        guard sidecar.provenance.locator.table == "INOUTCOME",
          let columnName = sidecar.provenance.locator.columnName,
          columnName.caseInsensitiveCompare("uid") == .orderedSame
        else { return false }
        return sidecar.storageClass == .text
      })
    {
      let sql = """
        SELECT count(*)
        FROM sidecar_reference s
        JOIN provenance_reference p ON p.provenance_id=s.provenance_id
        WHERE p.profile_id=:profile AND p.adapter_version=:adapter
          AND p.source_table='INOUTCOME' AND lower(p.source_column_name)='uid'
          AND s.storage_class='text' AND s.payload=:payload
        """
      return try countRows(
        database, sql: sql,
        values: [
          .text(event.amountProvenance.profileID), .text(event.amountProvenance.adapterVersion),
          .blob(uid.payload),
        ]) > 0
    }
    let locator = event.amountProvenance.locator
    let sql = """
      SELECT count(*) FROM economic_event e
      JOIN provenance_reference p ON p.provenance_id=e.provenance_id
      WHERE p.profile_id=? AND p.adapter_version=? AND p.source_table=?
        AND p.source_record_key=? AND e.account_id=? AND e.event_kind=?
        AND e.amount_literal=? AND e.currency_unit=?
      """
    let count = try countRows(
      database, sql: sql,
      values: [
        .text(event.amountProvenance.profileID), .text(event.amountProvenance.adapterVersion),
        .text(locator.table), .text(locator.recordKey), .text(event.accountID),
        .text(event.kind.rawValue), .text(event.amount.amount.rawLiteral),
        .text(event.amount.unitCode),
      ])
    return count > 0
  }

  private func bindingMatches(
    _ binding: CanonicalEventSourceBinding, eventID: String, database: OpaquePointer
  ) throws -> Bool {
    var statement: OpaquePointer?
    let sql = """
      SELECT declared_type, storage_class FROM event_source_binding
      WHERE event_id=? AND semantic=? AND provenance_id=?
      """
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement,
      bind(.text(eventID), to: statement, at: 1),
      bind(.text(binding.semantic.rawValue), to: statement, at: 2),
      bind(.text(binding.provenance.deterministicID), to: statement, at: 3)
    else { throw CanonicalCommitError.canonicalReadFailed }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return false }
    return columnOptionalText(statement, 0) == binding.declaredType
      && columnText(statement, 1) == binding.storageClass.rawValue
  }

  private func provenanceMatches(_ value: FieldProvenance, database: OpaquePointer) throws -> Bool {
    var statement: OpaquePointer?
    let sql =
      "SELECT artifact_sha256, profile_id, adapter_version, container_member, source_table, source_record_key, source_column_ordinal, source_column_name FROM provenance_reference WHERE provenance_id=?"
    let cached = CommitStatementCache.statement(database, sql)
    if cached == nil {
      guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
        throw CanonicalCommitError.canonicalReadFailed
      }
    } else {
      statement = cached
    }
    guard let statement, bind(.text(value.deterministicID), to: statement, at: 1) else {
      if cached == nil { sqlite3_finalize(statement) }
      throw CanonicalCommitError.canonicalReadFailed
    }
    defer {
      if cached == nil {
        sqlite3_finalize(statement)
      } else {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
      }
    }
    guard sqlite3_step(statement) == SQLITE_ROW else { return false }
    return columnText(statement, 0) == value.artifactSHA256
      && columnText(statement, 1) == value.profileID
      && columnText(statement, 2) == value.adapterVersion
      && columnOptionalText(statement, 3) == value.locator.containerMember
      && columnText(statement, 4) == value.locator.table
      && columnText(statement, 5) == value.locator.recordKey
      && columnOptionalInt(statement, 6) == value.locator.columnOrdinal
      && columnOptionalText(statement, 7) == value.locator.columnName
  }

  private func readSidecars(
    _ database: OpaquePointer, eventID: String
  ) throws -> [CanonicalPersistedSidecar] {
    var statement: OpaquePointer?
    let sql = """
      SELECT s.sidecar_id, s.provenance_id, s.format_version, s.declared_type, s.storage_class,
             length(s.payload), s.payload,
             p.artifact_sha256, p.profile_id, p.adapter_version, p.container_member,
             p.source_table, p.source_record_key, p.source_column_ordinal, p.source_column_name
      FROM sidecar_reference s
      JOIN provenance_reference p ON p.provenance_id=s.provenance_id
      WHERE s.event_id=? ORDER BY s.sidecar_id
      """
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement, bind(.text(eventID), to: statement, at: 1)
    else { throw CanonicalCommitError.canonicalReadFailed }
    defer { sqlite3_finalize(statement) }
    var values: [CanonicalPersistedSidecar] = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { return values }
      guard result == SQLITE_ROW, let sidecarID = columnText(statement, 0),
        let provenanceID = columnText(statement, 1),
        sqlite3_column_type(statement, 2) == SQLITE_INTEGER,
        let storageLiteral = columnText(statement, 4),
        let storageClass = CanonicalFieldStorageClass(rawValue: storageLiteral),
        sqlite3_column_type(statement, 5) == SQLITE_INTEGER,
        sqlite3_column_int64(statement, 5) >= 0,
        sqlite3_column_int64(statement, 5)
          <= Int64(CanonicalCommitDigest.maximumSidecarBytes),
        let payload = columnBlob(statement, 6), let artifactSHA256 = columnText(statement, 7),
        let profileID = columnText(statement, 8), let adapterVersion = columnText(statement, 9),
        let sourceTable = columnText(statement, 11), let recordKey = columnText(statement, 12)
      else { throw CanonicalCommitError.canonicalReadFailed }
      let provenance = FieldProvenance(
        artifactSHA256: artifactSHA256, profileID: profileID, adapterVersion: adapterVersion,
        locator: SourceLocator(
          containerMember: columnOptionalText(statement, 10), table: sourceTable,
          recordKey: recordKey, columnOrdinal: columnOptionalInt(statement, 13),
          columnName: columnOptionalText(statement, 14)), deterministicID: provenanceID)
      do {
        values.append(
          try CanonicalPersistedSidecar(
            sidecarID: sidecarID, eventID: eventID,
            formatVersion: Int(sqlite3_column_int64(statement, 2)),
            declaredType: columnOptionalText(statement, 3), storageClass: storageClass,
            payload: payload, provenance: provenance,
            maximumBytes: CanonicalCommitDigest.maximumSidecarBytes))
      } catch { throw CanonicalCommitError.canonicalReadFailed }
    }
  }

  private func readReceiptOwnedPreservation(
    _ database: OpaquePointer, receipt: String
  ) throws -> CanonicalReceiptOwnedPreservation {
    var anchors: [CanonicalReceiptOwnedAnchor] = []
    var anchorStatement: OpaquePointer?
    let anchorSQL = """
      SELECT a.anchor_id, a.idempotency_key, a.source_subject_id, a.subject_kind,
             m.subject_kind, m.anchor_subject_kind, a.artifact_sha256, a.profile_id, a.adapter_version,
             a.container_member, a.source_table, a.source_record_key
      FROM receipt_preservation_membership m
      JOIN receipt_preservation_anchor a ON a.idempotency_key=m.idempotency_key
        AND a.anchor_id=m.anchor_id
      WHERE m.idempotency_key=? AND m.subject_kind IN ('table', 'record')
      ORDER BY a.anchor_id
      """
    guard sqlite3_prepare_v2(database, anchorSQL, -1, &anchorStatement, nil) == SQLITE_OK,
      let anchorStatement, bind(.text(receipt), to: anchorStatement, at: 1)
    else { throw CanonicalCommitError.canonicalReadFailed }
    defer { sqlite3_finalize(anchorStatement) }
    while true {
      let result = sqlite3_step(anchorStatement)
      if result == SQLITE_DONE { break }
      guard result == SQLITE_ROW, let anchorID = columnText(anchorStatement, 0),
        columnText(anchorStatement, 1) == receipt,
        let subjectID = columnText(anchorStatement, 2),
        let kindLiteral = columnText(anchorStatement, 3),
        let kind = CanonicalPreservationSubjectKind(rawValue: kindLiteral),
        columnText(anchorStatement, 4) == kindLiteral,
        columnText(anchorStatement, 5) == kindLiteral,
        let artifact = columnText(anchorStatement, 6),
        let profile = columnText(anchorStatement, 7),
        let adapter = columnText(anchorStatement, 8),
        let table = columnText(anchorStatement, 10),
        subjectID
          == (kind == .table
            ? StableStagingID.table(stagingID: receipt, table: table)
            : StableStagingID.record(
              stagingID: receipt, table: table,
              recordKey: columnOptionalText(anchorStatement, 11) ?? ""))
      else { throw CanonicalCommitError.canonicalReadFailed }
      do {
        anchors.append(
          try CanonicalReceiptOwnedAnchor(
            anchorID: anchorID, receiptID: receipt,
            sourceSubjectID: subjectID, subjectKind: kind,
            artifactSHA256: artifact, profileID: profile, adapterVersion: adapter,
            containerMember: columnOptionalText(anchorStatement, 9), sourceTable: table,
            sourceRecordKey: columnOptionalText(anchorStatement, 11)))
      } catch { throw CanonicalCommitError.canonicalReadFailed }
    }

    var payloads: [CanonicalReceiptOwnedPayload] = []
    var payloadStatement: OpaquePointer?
    let payloadSQL = """
      SELECT x.payload_id, x.idempotency_key, x.anchor_id, x.source_subject_id, x.provenance_id,
             x.format_version, x.declared_type, x.storage_class, length(x.payload), x.payload,
             m.subject_kind, m.anchor_subject_kind,
             p.artifact_sha256, p.profile_id, p.adapter_version, p.container_member,
             p.source_table, p.source_record_key, p.source_column_ordinal, p.source_column_name
      FROM receipt_preservation_membership m
      JOIN receipt_preservation_payload x ON x.idempotency_key=m.idempotency_key
        AND x.payload_id=m.payload_id
      JOIN provenance_reference p ON p.provenance_id=x.provenance_id
      WHERE m.idempotency_key=? AND m.subject_kind='field'
      ORDER BY x.payload_id
      """
    guard sqlite3_prepare_v2(database, payloadSQL, -1, &payloadStatement, nil) == SQLITE_OK,
      let payloadStatement, bind(.text(receipt), to: payloadStatement, at: 1)
    else { throw CanonicalCommitError.canonicalReadFailed }
    defer { sqlite3_finalize(payloadStatement) }
    while true {
      let result = sqlite3_step(payloadStatement)
      if result == SQLITE_DONE { break }
      guard result == SQLITE_ROW, let payloadID = columnText(payloadStatement, 0),
        columnText(payloadStatement, 1) == receipt,
        let anchorID = columnText(payloadStatement, 2),
        let subjectID = columnText(payloadStatement, 3),
        let provenanceID = columnText(payloadStatement, 4),
        sqlite3_column_type(payloadStatement, 5) == SQLITE_INTEGER,
        let storageLiteral = columnText(payloadStatement, 7),
        let storageClass = CanonicalFieldStorageClass(rawValue: storageLiteral),
        sqlite3_column_type(payloadStatement, 8) == SQLITE_INTEGER,
        sqlite3_column_int64(payloadStatement, 8) >= 0,
        sqlite3_column_int64(payloadStatement, 8)
          <= Int64(CanonicalCommitDigest.maximumSidecarBytes),
        let payload = columnBlob(payloadStatement, 9),
        columnText(payloadStatement, 10) == "field",
        columnText(payloadStatement, 11) == CanonicalPreservationSubjectKind.record.rawValue,
        let artifact = columnText(payloadStatement, 12),
        let profile = columnText(payloadStatement, 13),
        let adapter = columnText(payloadStatement, 14),
        let table = columnText(payloadStatement, 16),
        let recordKey = columnText(payloadStatement, 17)
      else { throw CanonicalCommitError.canonicalReadFailed }
      let locator = SourceLocator(
        containerMember: columnOptionalText(payloadStatement, 15), table: table,
        recordKey: recordKey, columnOrdinal: columnOptionalInt(payloadStatement, 18),
        columnName: columnOptionalText(payloadStatement, 19))
      guard subjectID == StableStagingID.field(stagingID: receipt, locator: locator) else {
        throw CanonicalCommitError.canonicalReadFailed
      }
      let provenance = FieldProvenance(
        artifactSHA256: artifact, profileID: profile, adapterVersion: adapter,
        locator: locator, deterministicID: provenanceID)
      do {
        payloads.append(
          try CanonicalReceiptOwnedPayload(
            payloadID: payloadID, receiptID: receipt,
            anchorID: anchorID, sourceSubjectID: subjectID,
            formatVersion: Int(sqlite3_column_int64(payloadStatement, 5)),
            declaredType: columnOptionalText(payloadStatement, 6), storageClass: storageClass,
            payload: payload, provenance: provenance,
            maximumBytes: CanonicalCommitDigest.maximumSidecarBytes))
      } catch { throw CanonicalCommitError.canonicalReadFailed }
    }
    return CanonicalReceiptOwnedPreservation(anchors: anchors, payloads: payloads)
  }

  private func run(_ database: OpaquePointer, sql: String, values: [SQLValue]) throws {
    if let statement = CommitStatementCache.statement(database, sql) {
      defer {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
      }
      for (offset, value) in values.enumerated() {
        guard bind(value, to: statement, at: Int32(offset + 1)) else {
          throw CanonicalCommitError.canonicalWriteFailed
        }
      }
      guard sqlite3_step(statement) == SQLITE_DONE else {
        throw CanonicalCommitError.canonicalWriteFailed
      }
      return
    }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw CanonicalCommitError.canonicalWriteFailed }
    defer { sqlite3_finalize(statement) }
    for (offset, value) in values.enumerated() {
      guard bind(value, to: statement, at: Int32(offset + 1)) else {
        throw CanonicalCommitError.canonicalWriteFailed
      }
    }
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw CanonicalCommitError.canonicalWriteFailed
    }
  }

  private func bind(_ value: SQLValue, to statement: OpaquePointer, at index: Int32) -> Bool {
    switch value {
    case .text(let text):
      return text.withCString {
        sqlite3_bind_text(
          statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
          == SQLITE_OK
      }
    case .optionalText(let text):
      guard let text else { return sqlite3_bind_null(statement, index) == SQLITE_OK }
      return bind(.text(text), to: statement, at: index)
    case .int(let value):
      return sqlite3_bind_int64(statement, index, Int64(value)) == SQLITE_OK
    case .optionalInt(let value):
      guard let value else { return sqlite3_bind_null(statement, index) == SQLITE_OK }
      return sqlite3_bind_int64(statement, index, Int64(value)) == SQLITE_OK
    case .int64(let value):
      return sqlite3_bind_int64(statement, index, value) == SQLITE_OK
    case .blob(let data):
      if data.isEmpty { return sqlite3_bind_zeroblob(statement, index, 0) == SQLITE_OK }
      return data.withUnsafeBytes {
        sqlite3_bind_blob(
          statement, index, $0.baseAddress, Int32(data.count),
          unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK
      }
    }
  }

  private func execute(_ database: OpaquePointer, _ sql: String) -> Bool {
    sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
  }

  private func scalarInt(_ database: OpaquePointer, _ sql: String) -> Int? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { return nil }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
      sqlite3_column_type(statement, 0) == SQLITE_INTEGER
    else { return nil }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private func countRows(
    _ database: OpaquePointer, sql: String, values: [SQLValue]
  ) throws -> Int {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw CanonicalCommitError.canonicalReadFailed }
    defer { sqlite3_finalize(statement) }
    for (offset, value) in values.enumerated() {
      guard bind(value, to: statement, at: Int32(offset + 1)) else {
        throw CanonicalCommitError.canonicalReadFailed
      }
    }
    guard sqlite3_step(statement) == SQLITE_ROW,
      sqlite3_column_type(statement, 0) == SQLITE_INTEGER
    else { throw CanonicalCommitError.canonicalReadFailed }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private func scalarText(_ database: OpaquePointer, _ sql: String) -> String? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { return nil }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return columnText(statement, 0)
  }

  private func tableNames(_ database: OpaquePointer) -> [String] {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
        -1, &statement, nil) == SQLITE_OK, let statement
    else { return [] }
    defer { sqlite3_finalize(statement) }
    var names: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let name = columnText(statement, 0) else { return [] }
      names.append(name)
    }
    return names
  }

  private func schemaObjects(_ database: OpaquePointer) -> [CanonicalSchemaObject] {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT type, name, tbl_name, sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name",
        -1, &statement, nil) == SQLITE_OK, let statement
    else { return [] }
    defer { sqlite3_finalize(statement) }
    var objects: [CanonicalSchemaObject] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let type = columnText(statement, 0), let name = columnText(statement, 1),
        let tableName = columnText(statement, 2), let ddl = columnText(statement, 3)
      else { return [] }
      objects.append(
        CanonicalSchemaObject(
          type: type, name: name, tableName: tableName,
          ddl: CanonicalLedgerSchema.normalizedDDL(ddl)))
    }
    return objects
  }

  private func queryHasNoRows(_ database: OpaquePointer, _ sql: String) -> Bool {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { return false }
    defer { sqlite3_finalize(statement) }
    return sqlite3_step(statement) == SQLITE_DONE
  }

  private func persistedPayloadSizesAreBounded(_ database: OpaquePointer) -> Bool {
    queryHasNoRows(
      database,
      "SELECT 1 FROM sidecar_reference WHERE length(payload)>\(CanonicalCommitDigest.maximumSidecarBytes)"
    )
      && queryHasNoRows(
        database,
        "SELECT 1 FROM receipt_preservation_payload WHERE length(payload)>\(CanonicalCommitDigest.maximumSidecarBytes)"
      )
      && queryHasNoRows(
        database,
        "SELECT 1 WHERE (SELECT coalesce(sum(length(payload)),0) FROM sidecar_reference) + (SELECT coalesce(sum(length(payload)),0) FROM receipt_preservation_payload) > \(CanonicalCommitDigest.maximumTotalSidecarBytes)"
      )
  }

  private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) == SQLITE_TEXT else { return nil }
    let count = Int(sqlite3_column_bytes(statement, index))
    if count == 0 { return "" }
    guard let bytes = sqlite3_column_text(statement, index) else { return nil }
    return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
  }

  private func columnOptionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
    sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : columnText(statement, index)
  }

  private func columnOptionalInt(_ statement: OpaquePointer, _ index: Int32) -> Int? {
    sqlite3_column_type(statement, index) == SQLITE_NULL
      ? nil : Int(sqlite3_column_int64(statement, index))
  }

  private func columnBlob(_ statement: OpaquePointer, _ index: Int32) -> Data? {
    guard sqlite3_column_type(statement, index) == SQLITE_BLOB else { return nil }
    let count = Int(sqlite3_column_bytes(statement, index))
    if count == 0 { return Data() }
    guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
    return Data(bytes: bytes, count: count)
  }
}

private enum SQLValue {
  case text(String)
  case optionalText(String?)
  case int(Int)
  case optionalInt(Int?)
  case int64(Int64)
  case blob(Data)
}

private struct Receipt {
  let stagingDigest: String
  let artifactSHA256: String
  let profileID: String
  let adapterVersion: String
  /// Stored in the legacy `reconciliation_hash` column as a canonical receipt-integrity anchor.
  let integrityHash: String
  let eventSetHash: String
  let eventCount: Int
}

private struct OpenedCanonicalDatabase {
  let database: OpaquePointer
  let pinnedIdentity: stat
  let created: Bool
  let creationDescriptor: Int32?
}

struct StagingGraph {
  var tables: [String: StagedTableTarget] = [:]
  var records: [String: StagedRecordTarget] = [:]
  var fields: [String: StagedFieldTarget] = [:]
}

struct StagedTableTarget {
  let name: String
}

struct StagedRecordTarget {
  let tableID: String
  let recordKey: String
}

struct StagedFieldTarget {
  let recordID: String
  let ordinal: Int
  let columnName: String
  let declaredType: String?
  let storageClass: String
  let payload: Data
  let sidecarVersion: Int
  let containerMember: String?
}

private struct TrustedCommitPlan {
  let decisions: [ReconciliationDecision]
  let sidecarsByEvent: [String: [CanonicalPersistedSidecar]]
  let receiptOwnedAnchors: [CanonicalReceiptOwnedAnchor]
  let receiptOwnedPayloads: [CanonicalReceiptOwnedPayload]
}

private final class CanonicalReadSnapshot {
  let database: OpaquePointer
  private let descriptor: Int32
  private let identity: stat
  private let url: URL
  private var isClosed = false

  init(database: OpaquePointer, descriptor: Int32, identity: stat, url: URL) {
    self.database = database
    self.descriptor = descriptor
    self.identity = identity
    self.url = url
  }

  func validatePathIdentity() throws {
    var descriptorAfter = stat()
    var pathAfter = stat()
    guard !isClosed,
      fstat(descriptor, &descriptorAfter) == 0,
      lstat(url.path, &pathAfter) == 0,
      Self.sameIdentity(identity, descriptorAfter),
      Self.sameIdentity(identity, pathAfter),
      Self.noSQLiteCompanions(url)
    else { throw CanonicalCommitError.incompatibleCanonicalStore }
  }

  func close() {
    guard !isClosed else { return }
    isClosed = true
    sqlite3_close(database)
    Darwin.close(descriptor)
  }

  deinit { close() }

  static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
      && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
      && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
      && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
      && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
  }

  private static func noSQLiteCompanions(_ url: URL) -> Bool {
    for suffix in ["-journal", "-wal", "-shm"] {
      var companion = stat()
      errno = 0
      guard lstat(url.path + suffix, &companion) != 0, errno == ENOENT else { return false }
    }
    return true
  }
}

private final class StagingSnapshot: @unchecked Sendable {
  let database: OpaquePointer
  var descriptorSize: Int64 { Int64(identity.st_size) }
  private let descriptor: Int32
  private let identity: stat
  private let url: URL
  private var isClosed = false

  private init(database: OpaquePointer, descriptor: Int32, identity: stat, url: URL) {
    self.database = database
    self.descriptor = descriptor
    self.identity = identity
    self.url = url
  }

  static func open(_ url: URL) throws -> StagingSnapshot {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw CanonicalCommitError.unauthenticatedStaging }
    var identity = stat()
    var pathIdentity = stat()
    guard fstat(descriptor, &identity) == 0,
      lstat(url.path, &pathIdentity) == 0,
      isAcceptable(identity), sameIdentity(identity, pathIdentity), noSQLiteCompanions(url)
    else {
      Darwin.close(descriptor)
      throw CanonicalCommitError.unauthenticatedStaging
    }
    let sqliteDescriptor = dup(descriptor)
    guard sqliteDescriptor >= 0 else {
      Darwin.close(descriptor)
      throw CanonicalCommitError.unauthenticatedStaging
    }
    defer { Darwin.close(sqliteDescriptor) }
    var database: OpaquePointer?
    let uri = "file:/dev/fd/\(sqliteDescriptor)?mode=ro&immutable=1"
    guard
      sqlite3_open_v2(
        uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
        == SQLITE_OK, let database, sqlite3_db_readonly(database, "main") == 1,
      // The staging copy of a real backup is a few hundred MB and is read in key order across
      // several indexes; SQLite's default 2 MB page cache re-reads the same pages from disk.
      sqlite3_exec(database, "PRAGMA cache_size=-262144", nil, nil, nil) == SQLITE_OK
    else {
      if database != nil { sqlite3_close(database) }
      Darwin.close(descriptor)
      throw CanonicalCommitError.unauthenticatedStaging
    }
    return StagingSnapshot(database: database, descriptor: descriptor, identity: identity, url: url)
  }

  func validatePathIdentity() throws {
    var descriptorAfter = stat()
    var pathAfter = stat()
    guard !isClosed,
      fstat(descriptor, &descriptorAfter) == 0,
      lstat(url.path, &pathAfter) == 0,
      Self.sameIdentity(identity, descriptorAfter), Self.sameIdentity(identity, pathAfter),
      Self.noSQLiteCompanions(url)
    else { throw CanonicalCommitError.unauthenticatedStaging }
  }

  func close() {
    guard !isClosed else { return }
    isClosed = true
    sqlite3_close(database)
    Darwin.close(descriptor)
  }

  deinit { close() }

  private static func isAcceptable(_ value: stat) -> Bool {
    (value.st_mode & S_IFMT) == S_IFREG && value.st_size > 0
      && value.st_size <= CanonicalStagingPreflight.maximumDatabaseBytes
  }

  private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
      && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
      && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
      && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
      && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
  }

  private static func noSQLiteCompanions(_ url: URL) -> Bool {
    for suffix in ["-journal", "-wal", "-shm"] {
      var companion = stat()
      errno = 0
      if lstat(url.path + suffix, &companion) == 0 || errno != ENOENT { return false }
    }
    return true
  }
}

private struct PreparedCommit {
  let snapshot: StagingSnapshot
  let graph: StagingGraph
  let plan: TrustedCommitPlan
  let report: ReconciliationReport
}

private struct ImportedCategoryRow {
  let uid: String
  let id: String
  let name: String
  let kind: LedgerCategoryKind
  let parentUID: String?
  let displayOrder: Int
}

/// Prepared statements reused for the length of one commit connection. A real backup runs the
/// same few INSERT and lookup statements hundreds of thousands of times, and preparing each
/// one again was about a sixth of the commit. Users reset a statement after each use; `end`
/// finalizes them all before the connection closes.
enum CommitStatementCache {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var caches: [OpaquePointer: [String: OpaquePointer]] = [:]
  /// Enough for every fixed statement the commit runs; anything beyond is prepared each time.
  private static let limit = 64

  static func begin(_ database: OpaquePointer) {
    lock.withLock { caches[database] = [:] }
  }

  static func end(_ database: OpaquePointer) {
    let statements = lock.withLock { caches.removeValue(forKey: database) } ?? [:]
    for statement in statements.values { sqlite3_finalize(statement) }
  }

  /// The cached statement for `sql`, prepared on first use, or nil when `database` has no
  /// cache (or it is full), in which case the caller prepares and finalizes its own.
  static func statement(_ database: OpaquePointer, _ sql: String) -> OpaquePointer? {
    lock.withLock {
      guard var cache = caches[database] else { return nil }
      if let statement = cache[sql] { return statement }
      guard cache.count < limit else { return nil }
      var statement: OpaquePointer?
      guard sqlite3_prepare_v3(
        database, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &statement, nil) == SQLITE_OK,
        let statement
      else {
        sqlite3_finalize(statement)
        return nil
      }
      cache[sql] = statement
      caches[database] = cache
      return statement
    }
  }
}
