import CSQLite
import Darwin
import Foundation
import LedgerAdapterSemantics
import LedgerCore

/// Strict, evidence-labelled projection of the one observed Android SQLite v19 profile.
/// It never invents transfer direction, timezone, or unknown type semantics.
public enum MoneyManagerV19ObservedSchema {
  public static let tableNames: [String] = [
    "ASSETGROUP", "ASSETS", "BUDGET", "BUDGET_AMOUNT", "CODE_DATA", "CODE_LINK", "CURRENCY",
    "FAVTRANSACTION", "INOUTCOME", "MEMO", "MESSAGEMACRO2", "PHOTO", "REPEATTRANSACTION",
    "SMS_RAW_READ", "TAG", "TX_TAG", "ZCATEGORY", "ZETC", "android_metadata",
  ]

  public enum AttachmentState: String, Codable, Equatable, Sendable {
    case present, missing, orphaned, deleted
  }

  public static func inventory(tableNames: [String]) -> [String] {
    tableNames.sorted()
  }
}

public enum MoneyManagerV19Adapter {
  public static let version = MoneyManagerV19Semantics.adapterVersion
  public static let sourceProfileID = SourceProfile.observedAndroidV19.identifier
  public static let observedProfileID = "realbyte-android-v19-synthetic-text-subset-v1"

  public static let admittedProfileIDs = MoneyManagerV19Semantics.admittedProfileIDs

  public static func admits(_ profile: SourceProfile) -> Bool {
    admittedProfileIDs.contains(profile.identifier)
  }

  public static func prepare(_ input: MoneyManagerV19AdapterInput) throws -> MoneyManagerV19Plan {
    // Arrays carry no authenticated relationship to a staged artifact.
    throw MoneyManagerV19AdapterError.invalidStagingInventory
  }

  /// Produces a projection only from a descriptor-bound, read-only staging inventory.
  public static func prepare(
    stagingDatabaseURL: URL,
    expectedManifest: StagingManifest,
    expectedContentDigest: String
  ) throws -> MoneyManagerV19Plan {
    guard admittedProfileIDs.contains(expectedManifest.profileID),
      expectedManifest.adapterVersion == version,
      expectedManifest.stagingID
        == StableStagingID.stage(
          artifactSHA256: expectedManifest.artifactSHA256, profileID: expectedManifest.profileID,
          adapterVersion: version),
      CanonicalIdentifier.isValid(expectedContentDigest)
    else { throw MoneyManagerV19AdapterError.unsupportedProfile }
    return try project(
      authenticatedInput(
        at: stagingDatabaseURL, manifest: expectedManifest, digest: expectedContentDigest,
        testingMutation: nil))
  }

  static func prepare(
    stagingDatabaseURL: URL, expectedManifest: StagingManifest,
    expectedContentDigest: String,
    testingMutation: @escaping (MoneyManagerV19AdapterReadPoint) throws -> Void
  ) throws -> MoneyManagerV19Plan {
    try project(
      authenticatedInput(
        at: stagingDatabaseURL, manifest: expectedManifest, digest: expectedContentDigest,
        testingMutation: testingMutation))
  }

  /// Authenticates the stage and derives the only canonical request admitted for the observed
  /// v19 profile. `ZDATE` is an observed local epoch-millisecond encoding: its wall-clock
  /// components are resolved in the caller-supplied zone and are never inferred to be UTC.
  package static func canonicalCommitRequest(
    canonicalDatabaseURL: URL,
    stagingDatabaseURL: URL,
    expectedManifest: StagingManifest,
    expectedContentDigest: String,
    sourceTimeZone: SourceTimeZone
  ) throws -> CanonicalCommitRequest {
    try canonicalCommitRequest(
      canonicalDatabaseURL: canonicalDatabaseURL, stagingDatabaseURL: stagingDatabaseURL,
      expectedManifest: expectedManifest, expectedContentDigest: expectedContentDigest,
      sourceTimeZone: sourceTimeZone, testingMutation: nil)
  }

  static func canonicalCommitRequest(
    canonicalDatabaseURL: URL, stagingDatabaseURL: URL,
    expectedManifest: StagingManifest, expectedContentDigest: String,
    sourceTimeZone: SourceTimeZone,
    testingMutation: @escaping (MoneyManagerV19AdapterReadPoint) throws -> Void
  ) throws -> CanonicalCommitRequest {
    try canonicalCommitRequest(
      canonicalDatabaseURL: canonicalDatabaseURL, stagingDatabaseURL: stagingDatabaseURL,
      expectedManifest: expectedManifest, expectedContentDigest: expectedContentDigest,
      sourceTimeZone: sourceTimeZone, testingMutation: Optional(testingMutation))
  }

  private static func canonicalCommitRequest(
    canonicalDatabaseURL: URL, stagingDatabaseURL: URL,
    expectedManifest: StagingManifest, expectedContentDigest: String,
    sourceTimeZone: SourceTimeZone,
    testingMutation: ((MoneyManagerV19AdapterReadPoint) throws -> Void)?
  ) throws -> CanonicalCommitRequest {
    let input = try authenticatedInput(
      at: stagingDatabaseURL, manifest: expectedManifest, digest: expectedContentDigest,
      testingMutation: testingMutation)
    let plan = try project(input)
    guard !plan.isBlocked else { throw MoneyManagerV19AdapterError.semanticBindingRequired }

    let recordsByID = Dictionary(
      uniqueKeysWithValues: input.allRecords.map {
        ($0.sourceRecordID, $0)
      })
    var events: [CanonicalEconomicEvent] = []
    for mapped in plan.mappedEvents {
      guard let record = recordsByID[mapped.sourceRecordID],
        sourceField(record, aliases: MoneyManagerV19Vocabulary.uidAliases) != nil
      else { throw MoneyManagerV19AdapterError.semanticBindingRequired }
      let amount = mapped.amount
      let zdate = mapped.timestamp.zdate
      let account = mapped.account
      let type =
        sourceField(record, aliases: MoneyManagerV19Vocabulary.doTypeAliases) ?? mapped.amount
      let temporal = try canonicalTemporal(mapped.timestamp, sourceTimeZone: sourceTimeZone)
      let bindings = try [
        binding(.amount, amount), binding(.currency, mapped.currency),
        binding(.occurredAt, zdate), binding(.account, account), binding(.kind, type),
      ]
      let sidecars = try record.fields.map {
        try CanonicalSidecarReference(
          sidecarID: $0.provenance.deterministicID,
          provenanceID: $0.provenance.deterministicID)
      }
      events.append(
        try CanonicalEconomicEvent(
          eventID: StableCanonicalID.event(sourceRecordID: mapped.sourceRecordID, effectOrdinal: 0),
          accountID: StableCanonicalID.account(
            profileID: input.manifest.profileID, sourceAccountID: account.value),
          kind: mapped.kind.canonical,
          amount: CurrencyAmount(
            unitCode: mapped.currency.value, amount: ExactDecimal(amount.value)),
          occurredAt: temporal, sourceRecordID: mapped.sourceRecordID,
          amountProvenance: amount.provenance, sourceBindings: bindings,
          sidecarReferences: sidecars))
    }
    let eventIDsByRecord = Dictionary(
      uniqueKeysWithValues: events.map { ($0.sourceRecordID, $0.eventID) })
    let transferPairs = try plan.transferPairs.map { pair -> CanonicalTransferPair in
      guard let debit = eventIDsByRecord[pair.debitRecordID],
        let credit = eventIDsByRecord[pair.creditRecordID]
      else { throw MoneyManagerV19AdapterError.semanticBindingRequired }
      return CanonicalTransferPair(
        transferID: MoneyManagerV19Vocabulary.transferID(debitEventID: debit, creditEventID: credit),
        debitEventID: debit, creditEventID: credit)
    }
    let eventRecordIDs = Set(events.map(\.sourceRecordID))
    let receiptOwnedRecords = input.allRecords.filter {
      !eventRecordIDs.contains($0.sourceRecordID)
    }
    let eventTableNames = Set(
      input.allRecords.filter { eventRecordIDs.contains($0.sourceRecordID) }.map(\.tableName))
    let receiptOwnedTableNames = input.allTableNames.filter { !eventTableNames.contains($0) }
    let receiptOwnedSubjectIDs = Set(
      receiptOwnedTableNames.map {
        StableStagingID.table(stagingID: input.manifest.stagingID, table: $0)
      } + receiptOwnedRecords.map(\.sourceRecordID)
        + receiptOwnedRecords.flatMap { $0.fields.map { $0.provenance.deterministicID } })
    guard !events.isEmpty || !receiptOwnedSubjectIDs.isEmpty else {
      throw MoneyManagerV19AdapterError.semanticBindingRequired
    }
    let decisions = reconciliationDecisions(
      input, eventRecordIDs: eventRecordIDs, preservedReasons: plan.preservedReasons)
    return CanonicalCommitRequest(
      observedV19CanonicalDatabaseURL: canonicalDatabaseURL,
      stagingDatabaseURL: stagingDatabaseURL, expectedManifest: input.manifest,
      expectedStagingDigest: input.stagingDigest, mappingDecisions: decisions,
      events: events, transferPairs: transferPairs,
      receiptOwnedSubjectIDs: receiptOwnedSubjectIDs, sourceTimeZone: sourceTimeZone)
  }

  private static func binding(
    _ semantic: CanonicalEventSourceSemantic, _ field: MoneyManagerV19SourceField
  ) throws -> CanonicalEventSourceBinding {
    try CanonicalEventSourceBinding(
      semantic: semantic, provenance: field.provenance,
      declaredType: field.declaredType, storageClass: field.storageClass)
  }

  /// ZDATE is a true UTC epoch (observed: WDATE equals ZDATE's civil day at the device's
  /// offset for every row of the real backup). The local wall time is the instant seen in the
  /// source time zone, and its day must equal WDATE.
  private static func canonicalTemporal(
    _ observed: MoneyManagerV19ObservedTimestamp, sourceTimeZone: SourceTimeZone
  ) throws -> SourceTemporal {
    guard
      let temporal = MoneyManagerV19Vocabulary.temporal(
        zdateEpochMilliseconds: observed.localEpochMilliseconds, in: sourceTimeZone),
      temporal.localDateTime.date == observed.localDay
    else { throw MoneyManagerV19AdapterError.semanticBindingRequired }
    return temporal
  }

  private static func reconciliationDecisions(
    _ input: MoneyManagerV19AdapterInput, eventRecordIDs: Set<String>,
    preservedReasons: [String: MoneyManagerV19BlockReason]
  ) -> [ReconciliationDecision] {
    var decisions = [
      ReconciliationDecision(
        subjectID: input.manifest.stagingID, kind: .artifact, disposition: .preserved,
        reasonCode: .immutableSourceProvenance)
    ]
    for tableName in input.allTableNames.sorted() {
      let mappedTable = input.allRecords.contains {
        $0.tableName == tableName && eventRecordIDs.contains($0.sourceRecordID)
      }
      decisions.append(
        ReconciliationDecision(
          subjectID: StableStagingID.table(stagingID: input.manifest.stagingID, table: tableName),
          kind: .table, disposition: mappedTable ? .mapped : .preserved,
          reasonCode: mappedTable ? .knownTableAdapter : .opaqueSidecarPreserved))
    }
    for record in input.allRecords.sorted(by: { $0.sourceRecordID < $1.sourceRecordID }) {
      let transaction = eventRecordIDs.contains(record.sourceRecordID)
      let recordReason =
        preservedReasons[record.sourceRecordID].map(MoneyManagerV19Vocabulary.reconciliationReason)
        ?? (transaction ? .knownRecordAdapter : .opaqueSidecarPreserved)
      decisions.append(
        ReconciliationDecision(
          subjectID: record.sourceRecordID, kind: .record,
          disposition: transaction ? .mapped : .preserved,
          reasonCode: transaction ? .knownRecordAdapter : recordReason))
      let fieldReason = transaction ? ReconciliationReasonCode.opaqueSidecarPreserved : recordReason
      decisions.append(
        contentsOf: record.fields.map {
          ReconciliationDecision(
            subjectID: $0.provenance.deterministicID, kind: .field,
            disposition: .preserved, reasonCode: fieldReason)
        })
    }
    return decisions
  }

  private static func project(_ input: MoneyManagerV19AdapterInput) throws -> MoneyManagerV19Plan {
    guard admittedProfileIDs.contains(input.manifest.profileID),
      input.manifest.adapterVersion == version,
      CanonicalIdentifier.isValid(input.manifest.stagingID),
      CanonicalIdentifier.isValid(input.stagingDigest)
    else { throw MoneyManagerV19AdapterError.unsupportedProfile }
    var events: [MoneyManagerV19MappedEvent] = []
    var blocked: [MoneyManagerV19BlockedRecord] = []
    var preservedReasons: [String: MoneyManagerV19BlockReason] = [:]
    let recognizedTables = MoneyManagerV19Vocabulary.recognizedTables
    var currenciesByUID: [String: MoneyManagerV19SourceField] = [:]
    for record in input.currencies {
      guard let uid = sourceField(record, aliases: MoneyManagerV19Vocabulary.uidAliases),
        let iso = sourceField(record, aliases: MoneyManagerV19Vocabulary.isoAliases),
        let uidKey = mappingLiteral(uid), let isoKey = mappingLiteral(iso),
        !uidKey.isEmpty, !isoKey.isEmpty
      else { throw MoneyManagerV19AdapterError.invalidSourceRecord }
      guard currenciesByUID.updateValue(iso, forKey: uidKey) == nil else {
        throw MoneyManagerV19AdapterError.invalidSourceRecord
      }
    }
    let accountUIDs = try uniqueUIDs(input.assets)
    let categoryUIDs = try uniqueUIDs(input.categories)
    for transaction in input.transactions {
      switch try map(
        transaction, accountUIDs: accountUIDs, categoryUIDs: categoryUIDs,
        currenciesByUID: currenciesByUID)
      {
      case .mapped(let event): events.append(event)
      case .preserved(let reason):
        preservedReasons[transaction.sourceRecordID] = reason
      case .blocked(let item): blocked.append(item)
      }
    }
    let pairs = pairTransfers(&events, preservedReasons: &preservedReasons)
    let opaqueTableNames = input.allTableNames.filter { !recognizedTables.contains($0) }
    let opaqueRecords = input.allRecords.filter { opaqueTableNames.contains($0.tableName) }
    let sourceBalances = try MoneyManagerV19BalanceOracle.balances(
      input, mappedRecordIDs: Set(events.map(\.sourceRecordID)))
    return MoneyManagerV19Plan(
      manifest: input.manifest, stagingDigest: input.stagingDigest,
      accounts: try input.assets.map { try entity(.account, $0) },
      categories: try input.categories.map { try entity(.category, $0) },
      currencies: try input.currencies.map { try entity(.currency, $0) },
      mappedEvents: events.sorted { $0.sourceRecordID < $1.sourceRecordID },
      transferPairs: pairs.sorted { $0.debitRecordID < $1.debitRecordID },
      opaqueTableNames: opaqueTableNames.sorted(),
      opaqueRecords: opaqueRecords.sorted { $0.sourceRecordID < $1.sourceRecordID },
      blockedRecords: blocked.sorted { $0.sourceRecordID < $1.sourceRecordID },
      preservedReasons: preservedReasons, sourceBalances: sourceBalances)
  }

  /// Matches transfer legs on their group id. A group that is not exactly one debit and one
  /// credit is preserved loudly; a same-account pair is preserved because it moves no money.
  private static func pairTransfers(
    _ events: inout [MoneyManagerV19MappedEvent],
    preservedReasons: inout [String: MoneyManagerV19BlockReason]
  ) -> [MoneyManagerV19TransferPair] {
    let legs = events.filter { $0.transferGroup != nil }
    var pairs: [MoneyManagerV19TransferPair] = []
    var unmapped: [String: MoneyManagerV19BlockReason] = [:]
    for (_, group) in Dictionary(grouping: legs, by: { $0.transferGroup! }) {
      let debits = group.filter { $0.kind == .transferDebit }
      let credits = group.filter { $0.kind == .transferCredit }
      guard group.count == 2, debits.count == 1, credits.count == 1 else {
        for leg in group { unmapped[leg.sourceRecordID] = .transferDirectionUnproven }
        continue
      }
      let debit = debits[0]
      let credit = credits[0]
      guard mappingLiteral(debit.account) != mappingLiteral(credit.account) else {
        unmapped[debit.sourceRecordID] = .sameAccountTransfer
        unmapped[credit.sourceRecordID] = .sameAccountTransfer
        continue
      }
      pairs.append(.init(debitRecordID: debit.sourceRecordID, creditRecordID: credit.sourceRecordID))
    }
    events.removeAll { unmapped[$0.sourceRecordID] != nil }
    preservedReasons.merge(unmapped) { _, new in new }
    return pairs
  }

  private static func uniqueUIDs(_ records: [MoneyManagerV19SourceRecord]) throws -> Set<String> {
    var values: Set<String> = []
    for record in records {
      guard let uid = sourceField(record, aliases: MoneyManagerV19Vocabulary.uidAliases),
        let key = mappingLiteral(uid), !key.isEmpty,
        values.insert(key).inserted
      else { throw MoneyManagerV19AdapterError.invalidSourceRecord }
    }
    return values
  }

  private static func entity(
    _ kind: MoneyManagerV19EntityKind, _ record: MoneyManagerV19SourceRecord
  ) throws -> MoneyManagerV19ObservedEntity {
    let expected: Set<String> =
      switch kind {
      case .account: ["ASSETS", "ZASSETS"]
      case .category: ["ZCATEGORY", "CATEGORY"]
      case .currency: ["CURRENCY", "ZCURRENCY"]
      }
    guard expected.contains(record.tableName) else {
      throw MoneyManagerV19AdapterError.invalidSourceRecord
    }
    return MoneyManagerV19ObservedEntity(
      kind: kind, sourceRecordID: record.sourceRecordID, fields: record.fields)
  }

  private static func authenticatedInput(
    at url: URL, manifest expected: StagingManifest, digest: String,
    testingMutation: ((MoneyManagerV19AdapterReadPoint) throws -> Void)?
  ) throws -> MoneyManagerV19AdapterInput {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw MoneyManagerV19AdapterError.invalidStagingInventory }
    defer { Darwin.close(descriptor) }
    var before = stat()
    var pathBefore = stat()
    guard fstat(descriptor, &before) == 0, lstat(url.path, &pathBefore) == 0,
      (before.st_mode & S_IFMT) == S_IFREG, sameIdentity(before, pathBefore), companionsAbsent(url)
    else { throw MoneyManagerV19AdapterError.invalidStagingInventory }
    let sqliteDescriptor = dup(descriptor)
    guard sqliteDescriptor >= 0 else { throw MoneyManagerV19AdapterError.invalidStagingInventory }
    defer { Darwin.close(sqliteDescriptor) }
    var database: OpaquePointer?
    guard
      sqlite3_open_v2(
        "file:/dev/fd/\(sqliteDescriptor)?mode=ro&immutable=1", &database,
        SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
      let database
    else {
      if database != nil { sqlite3_close(database) }
      throw MoneyManagerV19AdapterError.invalidStagingInventory
    }
    defer { sqlite3_close(database) }
    func validateIdentity() throws {
      var descriptorNow = stat()
      var pathNow = stat()
      guard fstat(descriptor, &descriptorNow) == 0, lstat(url.path, &pathNow) == 0,
        sameIdentity(before, descriptorNow), sameIdentity(before, pathNow),
        companionsAbsent(url)
      else { throw MoneyManagerV19AdapterError.invalidStagingInventory }
    }
    guard sqlite3_db_readonly(database, "main") == 1,
      CanonicalStagingPreflight.validate(
        database: database, descriptorSize: Int64(before.st_size), expected: expected),
      scalarText(database, "PRAGMA quick_check") == "ok",
      try storedManifest(database) == expected,
      scalarInt(database, "SELECT count(*) FROM staged_artifact") == 1,
      (try storedArtifact(database)).map({
        $0 == (
          expected.stagingID, expected.artifactSHA256,
          expected.profileID, expected.adapterVersion
        )
      }) == true,
      scalarInt(database, "SELECT count(*) FROM staging_manifest") == 1,
      scalarInt(database, "SELECT count(*) FROM staged_table") == expected.tableCount,
      scalarInt(database, "SELECT count(*) FROM staged_record") == expected.recordCount,
      scalarInt(database, "SELECT count(*) FROM staged_field") == expected.fieldCount,
      scalarInt(database, "SELECT coalesce(sum(length(payload)), 0) FROM staged_field")
        == expected.opaqueByteCount,
      scalarText(database, "SELECT value FROM staging_meta WHERE key='content_digest'") == digest,
      (try? SQLiteStagingStore().contentDigest(database: database)) == digest,
      scalarInt(database, "SELECT count(*) FROM pragma_foreign_key_check") == 0
    else { throw MoneyManagerV19AdapterError.invalidStagingInventory }
    try testingMutation?(.afterAuthentication)
    try validateIdentity()
    let rows = try stagedRecords(
      database, manifest: expected, testingMutation: testingMutation,
      validateIdentity: validateIdentity)
    let tableNames = try stagedTableNames(database)
    try validateIdentity()
    let tables = Dictionary(grouping: rows, by: \.tableName)
    return .init(
      manifest: expected, stagingDigest: digest,
      assets: tables["ASSETS", default: []] + tables["ZASSETS", default: []],
      categories: tables["ZCATEGORY", default: []] + tables["CATEGORY", default: []],
      currencies: tables["CURRENCY", default: []] + tables["ZCURRENCY", default: []],
      transactions: tables["INOUTCOME", default: []] + tables["ZINOUTCOME", default: []],
      allRecords: rows, allTableNames: tableNames)
  }

  private static func storedManifest(_ database: OpaquePointer) throws -> StagingManifest? {
    var statement: OpaquePointer?
    let sql =
      "SELECT format_version, staging_id, artifact_sha256, profile_id, adapter_version, table_count, record_count, field_count, opaque_byte_count FROM staging_manifest"
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      return nil
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW, let id = text(statement, 1),
      let artifact = text(statement, 2), let profile = text(statement, 3),
      let adapter = text(statement, 4)
    else { return nil }
    return .init(
      formatVersion: Int(sqlite3_column_int64(statement, 0)), stagingID: id,
      artifactSHA256: artifact, profileID: profile, adapterVersion: adapter,
      tableCount: Int(sqlite3_column_int64(statement, 5)),
      recordCount: Int(sqlite3_column_int64(statement, 6)),
      fieldCount: Int(sqlite3_column_int64(statement, 7)),
      opaqueByteCount: Int(sqlite3_column_int64(statement, 8)))
  }

  private static func storedArtifact(_ database: OpaquePointer) throws -> (
    String, String, String, String
  )? {
    var statement: OpaquePointer?
    let sql = "SELECT artifact_id,artifact_sha256,profile_id,adapter_version FROM staged_artifact"
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      return nil
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW, let id = text(statement, 0),
      let artifact = text(statement, 1), let profile = text(statement, 2),
      let adapter = text(statement, 3)
    else { return nil }
    return (id, artifact, profile, adapter)
  }

  private static func stagedTableNames(_ database: OpaquePointer) throws -> [String] {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database, "SELECT table_name FROM staged_table ORDER BY ordinal", -1,
        &statement, nil) == SQLITE_OK, let statement
    else { throw MoneyManagerV19AdapterError.invalidStagingInventory }
    defer { sqlite3_finalize(statement) }
    var names: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let name = text(statement, 0) else {
        throw MoneyManagerV19AdapterError.invalidStagingInventory
      }
      names.append(name)
    }
    return names
  }

  private static func stagedRecords(
    _ database: OpaquePointer, manifest: StagingManifest,
    testingMutation: ((MoneyManagerV19AdapterReadPoint) throws -> Void)?,
    validateIdentity: () throws -> Void
  ) throws -> [MoneyManagerV19SourceRecord] {
    let sql =
      "SELECT t.table_id,t.table_name,r.record_id,r.record_key,r.field_count,f.field_id,f.ordinal,f.column_name,f.declared_type,f.storage_class,length(f.payload),f.payload,f.container_member FROM staged_table t JOIN staged_record r ON r.table_id=t.table_id LEFT JOIN staged_field f ON f.record_id=r.record_id ORDER BY t.ordinal,r.record_key,f.ordinal"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw MoneyManagerV19AdapterError.invalidStagingInventory
    }
    defer { sqlite3_finalize(statement) }
    var output: [MoneyManagerV19SourceRecord] = []
    var activeID: String?
    var activeTable = ""
    var expectedFields = 0
    var fields: [MoneyManagerV19SourceField] = []
    var totalPayloadBytes = 0
    func finish() throws {
      guard activeID == nil || fields.count == expectedFields else {
        throw MoneyManagerV19AdapterError.invalidStagingInventory
      }
      if let activeID {
        output.append(try .init(tableName: activeTable, sourceRecordID: activeID, fields: fields))
      }
    }
    var invokedReadSeam = false
    var rowsSinceIdentityCheck = 0
    while sqlite3_step(statement) == SQLITE_ROW {
      if !invokedReadSeam {
        invokedReadSeam = true
        try testingMutation?(.duringStagedRecords)
      }
      // Re-check the staging file's identity every 1,024 rows rather than on every row: each
      // check is four stat calls, which were a quarter of preparing a real backup. The caller
      // checks again once all rows are read, so a swap is still caught before any row is used.
      if rowsSinceIdentityCheck == 0 { try validateIdentity() }
      rowsSinceIdentityCheck = (rowsSinceIdentityCheck + 1) % 1_024
      guard let tableID = text(statement, 0), let table = text(statement, 1),
        let recordID = text(statement, 2), let key = text(statement, 3)
      else { throw MoneyManagerV19AdapterError.invalidStagingInventory }
      let ordinal = Int(sqlite3_column_int64(statement, 6))
      let count = Int(sqlite3_column_int64(statement, 4))
      guard tableID == StableStagingID.table(stagingID: manifest.stagingID, table: table),
        recordID
          == StableStagingID.record(stagingID: manifest.stagingID, table: table, recordKey: key)
      else { throw MoneyManagerV19AdapterError.invalidStagingInventory }
      if activeID != recordID {
        try finish()
        activeID = recordID
        activeTable = table
        expectedFields = count
        fields = []
      }
      guard count > 0 else { continue }
      guard sqlite3_column_type(statement, 10) == SQLITE_INTEGER,
        sqlite3_column_int64(statement, 10) >= 0,
        sqlite3_column_int64(statement, 10) <= Int64(CanonicalCommitDigest.maximumSidecarBytes)
      else { throw MoneyManagerV19AdapterError.invalidStagingInventory }
      let payloadByteCount = Int(sqlite3_column_int64(statement, 10))
      let (newTotal, overflow) = totalPayloadBytes.addingReportingOverflow(payloadByteCount)
      guard !overflow, newTotal <= CanonicalCommitDigest.maximumTotalSidecarBytes else {
        throw MoneyManagerV19AdapterError.invalidStagingInventory
      }
      totalPayloadBytes = newTotal
      guard let fieldID = text(statement, 5), let name = text(statement, 7),
        let storage = text(statement, 9).flatMap(CanonicalFieldStorageClass.init(rawValue:)),
        let payload = blob(statement, 11), payload.count == payloadByteCount
      else { throw MoneyManagerV19AdapterError.invalidStagingInventory }
      let declared = sqlite3_column_type(statement, 8) == SQLITE_NULL ? nil : text(statement, 8)
      let member = sqlite3_column_type(statement, 12) == SQLITE_NULL ? nil : text(statement, 12)
      let locator = SourceLocator(
        containerMember: member, table: table, recordKey: key, columnOrdinal: ordinal,
        columnName: name)
      guard ordinal == fields.count,
        fieldID == StableStagingID.field(stagingID: manifest.stagingID, locator: locator),
        storage != .text || String(data: payload, encoding: .utf8) != nil
      else { throw MoneyManagerV19AdapterError.invalidStagingInventory }
      fields.append(
        try .init(
          name: name, payload: payload,
          provenance: .init(
            artifactSHA256: manifest.artifactSHA256, profileID: manifest.profileID,
            adapterVersion: manifest.adapterVersion, locator: locator, deterministicID: fieldID),
          declaredType: declared, storageClass: storage))
    }
    try finish()
    guard totalPayloadBytes == manifest.opaqueByteCount else {
      throw MoneyManagerV19AdapterError.invalidStagingInventory
    }
    return output
  }

  private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
      && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
      && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
      && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
      && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
  }
  private static func companionsAbsent(_ url: URL) -> Bool {
    ["-wal", "-shm", "-journal"].allSatisfy { suffix in
      var value = stat()
      return lstat(url.path + suffix, &value) != 0 && errno == ENOENT
    }
  }
  private static func scalarText(_ database: OpaquePointer, _ sql: String) -> String? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      return nil
    }
    defer { sqlite3_finalize(statement) }
    return sqlite3_step(statement) == SQLITE_ROW ? text(statement, 0) : nil
  }
  private static func scalarInt(_ database: OpaquePointer, _ sql: String) -> Int? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      return nil
    }
    defer { sqlite3_finalize(statement) }
    return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : nil
  }
  private static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) == SQLITE_TEXT else { return nil }
    let count = Int(sqlite3_column_bytes(statement, index))
    if count == 0 { return "" }
    guard let bytes = sqlite3_column_text(statement, index) else { return nil }
    return String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8)
  }
  private static func blob(_ statement: OpaquePointer, _ index: Int32) -> Data? {
    let count = Int(sqlite3_column_bytes(statement, index))
    guard count == 0 || sqlite3_column_blob(statement, index) != nil else { return nil }
    guard count > 0, let pointer = sqlite3_column_blob(statement, index) else { return Data() }
    return Data(bytes: pointer, count: count)
  }

  private static func map(
    _ record: MoneyManagerV19SourceRecord,
    accountUIDs: Set<String>,
    categoryUIDs: Set<String>,
    currenciesByUID: [String: MoneyManagerV19SourceField]
  ) throws -> Mapping {
    func blocked(_ reason: MoneyManagerV19BlockReason) -> Mapping {
      .blocked(.init(sourceRecordID: record.sourceRecordID, fields: record.fields, reason: reason))
    }
    func preserve(_ reason: MoneyManagerV19BlockReason) -> Mapping { .preserved(reason) }
    guard MoneyManagerV19Vocabulary.isTransactionTable(record.tableName) else {
      return blocked(.unexpectedTransactionTable)
    }
    guard let typeField = sourceField(record, aliases: MoneyManagerV19Vocabulary.doTypeAliases),
      let type = mappingLiteral(typeField)
    else {
      return preserve(.missingRequiredField)
    }
    if let deleted = sourceField(record, aliases: MoneyManagerV19Vocabulary.deletedAliases)
      .flatMap(mappingLiteral), !deleted.isEmpty, deleted != "0"
    {
      return preserve(.flaggedDeleted)
    }
    let categoryLiteral = sourceField(
      record, aliases: MoneyManagerV19Vocabulary.categoryAliases
    ).flatMap(mappingLiteral)
    if let reason = MoneyManagerV19Vocabulary.reason(forType: type, categoryUID: categoryLiteral) {
      return preserve(reason)
    }
    let isTransfer = MoneyManagerV19Vocabulary.isTransferType(type)
    guard let account = sourceField(record, aliases: MoneyManagerV19Vocabulary.assetAliases),
      let accountKey = mappingLiteral(account), accountUIDs.contains(accountKey),
      isTransfer || categoryLiteral != nil,
      let currencyUID = sourceField(record, aliases: MoneyManagerV19Vocabulary.currencyUIDAliases),
      let currencyKey = mappingLiteral(currencyUID),
      let currency = currenciesByUID[currencyKey],
      let amount = sourceField(record, aliases: MoneyManagerV19Vocabulary.amountAliases),
      let amountKey = mappingLiteral(amount),
      let wdate = sourceField(record, aliases: MoneyManagerV19Vocabulary.wdateAliases),
      let zdate = sourceField(record, aliases: MoneyManagerV19Vocabulary.zdateAliases),
      let day = parseDay(mappingLiteral(wdate) ?? wdate.value),
      let localEpoch = Int64(mappingLiteral(zdate) ?? zdate.value),
      let decimal = try? ExactDecimal(amountKey),
      (try? CurrencyAmount(unitCode: mappingLiteral(currency) ?? currency.value, amount: decimal))
        != nil
    else { return preserve(.missingRequiredField) }
    if let categoryLiteral, !isTransfer {
      guard MoneyManagerV19Vocabulary.categoryResolves(categoryLiteral, known: categoryUIDs) else {
        return preserve(.unresolvedCategory)
      }
    }
    var transferGroup: String?
    if isTransfer {
      guard
        let group = sourceField(record, aliases: MoneyManagerV19Vocabulary.transferGroupAliases)
          .flatMap(mappingLiteral),
        !group.isEmpty
      else { return preserve(.transferDirectionUnproven) }
      transferGroup = group
    }
    guard let kind = MoneyManagerV19Vocabulary.eventKind(forType: type) else {
      return preserve(.unknownTransactionType)
    }
    return .mapped(
      .init(
        sourceRecordID: record.sourceRecordID,
        kind: kind, account: account, amount: amount,
        currency: currency,
        timestamp: .init(
          wdate: wdate, zdate: zdate, localDay: day, localEpochMilliseconds: localEpoch),
        transferGroup: transferGroup,
        preservedFields: record.fields))
  }

  private static func sourceField(
    _ record: MoneyManagerV19SourceRecord, aliases: [String]
  ) -> MoneyManagerV19SourceField? {
    for name in aliases {
      if let field = record.field(named: name) { return field }
    }
    return nil
  }

  private static func mappingLiteral(_ field: MoneyManagerV19SourceField) -> String? {
    MoneyManagerV19Vocabulary.mappingLiteral(
      storageClass: field.storageClass, payload: field.payload, value: field.value)
  }

  private static func parseDay(_ literal: String) -> SourceLocalDate? {
    let parts = literal.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]),
      let day = Int(parts[2])
    else { return nil }
    return try? SourceLocalDate(year: year, month: month, day: day)
  }
}

enum MoneyManagerV19AdapterReadPoint: Equatable, Sendable {
  case afterAuthentication
  case duringStagedRecords
}

public enum MoneyManagerV19AdapterError: Error, Equatable, Sendable {
  case unsupportedProfile, invalidSourceRecord, invalidStagingInventory, semanticBindingRequired
}

public struct MoneyManagerV19AdapterInput: Sendable {
  public let manifest: StagingManifest
  /// A descriptor obtains this from read-only staging; a committer must re-authenticate it.
  public let stagingDigest: String
  public let assets, categories, currencies, transactions: [MoneyManagerV19SourceRecord]
  fileprivate let allRecords: [MoneyManagerV19SourceRecord]
  fileprivate let allTableNames: [String]
  public init(
    manifest: StagingManifest, stagingDigest: String, assets: [MoneyManagerV19SourceRecord],
    categories: [MoneyManagerV19SourceRecord], currencies: [MoneyManagerV19SourceRecord],
    transactions: [MoneyManagerV19SourceRecord], allRecords: [MoneyManagerV19SourceRecord]? = nil,
    allTableNames: [String]? = nil
  ) {
    self.manifest = manifest
    self.stagingDigest = stagingDigest
    self.assets = assets
    self.categories = categories
    self.currencies = currencies
    self.transactions = transactions
    self.allRecords = allRecords ?? assets + categories + currencies + transactions
    self.allTableNames = allTableNames ?? Set(self.allRecords.map(\.tableName)).sorted()
  }
}

public struct MoneyManagerV19SourceField: Equatable, Sendable {
  public let name, value: String
  /// Exact staged bytes, including opaque non-text/blob values.
  public let payload: Data
  public let provenance: FieldProvenance
  public let declaredType: String?
  public let storageClass: CanonicalFieldStorageClass
  public init(
    name: String, value: String, provenance: FieldProvenance, declaredType: String?,
    storageClass: CanonicalFieldStorageClass
  ) throws {
    guard !name.isEmpty, name.utf8.count <= 1_024, value.utf8.count <= 1_048_576,
      CanonicalIdentifier.isValid(provenance.deterministicID)
    else { throw MoneyManagerV19AdapterError.invalidSourceRecord }
    self.name = name
    self.value = value
    self.payload = Data(value.utf8)
    self.provenance = provenance
    self.declaredType = declaredType
    self.storageClass = storageClass
  }
  public init(
    name: String, payload: Data, provenance: FieldProvenance, declaredType: String?,
    storageClass: CanonicalFieldStorageClass
  ) throws {
    guard !name.isEmpty, name.utf8.count <= 1_024, payload.count <= 1_048_576,
      CanonicalIdentifier.isValid(provenance.deterministicID),
      storageClass != .text || String(data: payload, encoding: .utf8) != nil
    else { throw MoneyManagerV19AdapterError.invalidSourceRecord }
    self.name = name
    self.value = String(data: payload, encoding: .utf8) ?? ""
    self.payload = payload
    self.provenance = provenance
    self.declaredType = declaredType
    self.storageClass = storageClass
  }
  fileprivate var isText: Bool { storageClass == .text }
}

public struct MoneyManagerV19SourceRecord: Equatable, Sendable {
  public let tableName, sourceRecordID: String
  public let fields: [MoneyManagerV19SourceField]
  public init(tableName: String, sourceRecordID: String, fields: [MoneyManagerV19SourceField])
    throws
  {
    guard !tableName.isEmpty, CanonicalIdentifier.isValid(sourceRecordID),
      Set(fields.map(\.name)).count == fields.count
    else { throw MoneyManagerV19AdapterError.invalidSourceRecord }
    self.tableName = tableName
    self.sourceRecordID = sourceRecordID
    self.fields = fields.sorted { $0.name < $1.name }
  }
  fileprivate func field(named name: String) -> MoneyManagerV19SourceField? {
    fields.first { $0.name == name }
  }
}

public enum MoneyManagerV19EntityKind: String, Equatable, Sendable {
  case account, category, currency
}
public struct MoneyManagerV19ObservedEntity: Equatable, Sendable {
  public let kind: MoneyManagerV19EntityKind
  public let sourceRecordID: String
  public let fields: [MoneyManagerV19SourceField]
}
public enum MoneyManagerV19EventKind: String, Equatable, Sendable {
  case income, expense, adjustment, adjustmentDebit, transferDebit, transferCredit

  var canonical: CanonicalEventKind {
    switch self {
    case .income: .income
    case .expense: .expense
    case .adjustment: .adjustment
    case .adjustmentDebit: .adjustmentDebit
    case .transferDebit: .transferDebit
    case .transferCredit: .transferCredit
    }
  }
}
public struct MoneyManagerV19ObservedTimestamp: Equatable, Sendable {
  public let wdate, zdate: MoneyManagerV19SourceField
  public let localDay: SourceLocalDate
  /// Observed as local epoch milliseconds; it is deliberately not claimed as a UTC instant.
  public let localEpochMilliseconds: Int64
}
public struct MoneyManagerV19MappedEvent: Equatable, Sendable {
  public let sourceRecordID: String
  public let kind: MoneyManagerV19EventKind
  public let account, amount, currency: MoneyManagerV19SourceField
  public let timestamp: MoneyManagerV19ObservedTimestamp
  /// The shared group id for a transfer leg; nil for every other event.
  public let transferGroup: String?
  /// Includes all source fields so unmodelled values remain available for opaque sidecar handling.
  public let preservedFields: [MoneyManagerV19SourceField]
}
public enum MoneyManagerV19BlockReason: String, Equatable, Sendable {
  case unexpectedTransactionTable, nonTextField, missingRequiredField, invalidObservedLiteral,
    unresolvedCategory, transferDirectionUnproven, unknownTransactionType,
    unsupportedTransactionType, unknownStagedTable,
    /// Both legs of a transfer name the same account. It moves no money, so the legs are kept
    /// as preserved source records instead of a ledger transfer.
    sameAccountTransfer,
    /// The row carries a deletion flag. Money Manager removes deleted transactions instead of
    /// flagging them (observed), so a flagged row is unexplained: preserved, never imported.
    flaggedDeleted
}

/// The two source records of one transfer, matched on their shared group id.
public struct MoneyManagerV19TransferPair: Equatable, Sendable {
  public let debitRecordID: String
  public let creditRecordID: String
}
public struct MoneyManagerV19BlockedRecord: Equatable, Sendable {
  public let sourceRecordID: String
  public let fields: [MoneyManagerV19SourceField]
  public let reason: MoneyManagerV19BlockReason
}
public struct MoneyManagerV19Plan: Equatable, Sendable {
  public let manifest: StagingManifest
  public let stagingDigest: String
  public let accounts, categories, currencies: [MoneyManagerV19ObservedEntity]
  public let mappedEvents: [MoneyManagerV19MappedEvent]
  /// Every mapped transfer leg appears in exactly one pair.
  public let transferPairs: [MoneyManagerV19TransferPair]
  /// Unknown tables are retained even when they have zero records.
  public let opaqueTableNames: [String]
  /// Records from tables outside the observed v19 mapping are retained verbatim as opaque receipt data.
  public let opaqueRecords: [MoneyManagerV19SourceRecord]
  public let blockedRecords: [MoneyManagerV19BlockedRecord]
  public let preservedReasons: [String: MoneyManagerV19BlockReason]
  /// What Money Manager shows for each account, from the backup's own rows (#172).
  public let sourceBalances: MoneyManagerV19SourceBalances
  /// Raw v19 fields need a commit-layer semantic binding before a CanonicalCommitRequest can exist.
  public var requiresCanonicalSemanticBinding: Bool { true }
  public var isBlocked: Bool { false }
  public var blocksLosslessCertification: Bool {
    preservedReasons.values.contains { MoneyManagerV19Vocabulary.blocksLosslessCertification($0) }
  }

  package func canonicalCommitRequest() throws -> CanonicalCommitRequest {
    throw MoneyManagerV19AdapterError.semanticBindingRequired
  }
}
private enum Mapping {
  case mapped(MoneyManagerV19MappedEvent)
  case preserved(MoneyManagerV19BlockReason)
  case blocked(MoneyManagerV19BlockedRecord)
}
