import CSQLite
import Darwin
import Foundation

public enum ObservedV19SubjectRole: String, Codable, Equatable, Sendable {
  case account, category, currency, transaction, attachment, recurrence, budget, tag, auxiliary,
    metadata, unknown
}

public enum ObservedV19SubjectKind: String, Codable, Equatable, Sendable {
  case table, record, field

  var sortOrdinal: Int {
    switch self {
    case .table: 0
    case .record: 1
    case .field: 2
    }
  }
}

public enum ObservedV19SubjectDisposition: String, Codable, Equatable, Sendable {
  case mapped, preserved, excluded, blocked
}

public enum ObservedV19ReviewReasonCode: String, Codable, Equatable, Sendable {
  case publishedStructurePreserved = "published_structure_preserved"
  case unknownSubjectPreserved = "unknown_subject_preserved"
  case adapterMetadataTable = "adapter_metadata_table"
  case publishedTableMissing = "published_table_missing"
  case tombstoneEncodingUnknown = "tombstone_encoding_unknown"
  case columnAlphabetUncertified = "column_alphabet_uncertified"
}

public enum MoneyManagerV19ObservedSchemaError: Error, Equatable, Sendable {
  case unreadableSource
  case companionFilesPresent
  case invalidSQLite
  case hostileSize
}

public struct ObservedV19SubjectReview: Equatable, Sendable, Encodable {
  public let subjectID: String
  public let kind: ObservedV19SubjectKind
  public let ordinal: Int
  public let role: ObservedV19SubjectRole
  public let recordCount: UInt64
  public let fieldCount: UInt64
  public let nullCount: UInt64
  public let integerCount: UInt64
  public let realCount: UInt64
  public let textCount: UInt64
  public let blobCount: UInt64
  public let attachmentState: MoneyManagerV19ObservedSchema.AttachmentState?
  public let disposition: ObservedV19SubjectDisposition
  public let reasonCode: ObservedV19ReviewReasonCode
}

/// Deterministic, content-free loss-accounting of the published observed-v19 structure.
/// It does not map semantics and never claims a real v19 import certificate.
public struct ObservedV19StructureReview: Equatable, Sendable, Encodable, CustomStringConvertible {
  public let tableCount: Int
  public let recordCount: UInt64
  /// Schema column count across present tables. Distinct from `cellCount`.
  public let fieldCount: UInt64
  /// Storage-class occupancy (null+integer+real+text+blob). Distinct from `fieldCount`.
  public let cellCount: UInt64
  public let relationshipCount: UInt64
  /// L0 cannot certify a delete-flag encoding, so this stays 0.
  public let tombstoneCount: UInt64
  public let tombstoneReasonCode: ObservedV19ReviewReasonCode
  public let nullCount: UInt64
  public let integerCount: UInt64
  public let realCount: UInt64
  public let textCount: UInt64
  public let blobCount: UInt64
  public let subjectCount: Int
  public let mappedCount: Int
  public let preservedCount: Int
  public let excludedCount: Int
  public let blockedCount: Int
  public let attachmentPresentCount: Int
  public let attachmentMissingCount: Int
  public let attachmentOrphanedCount: Int
  public let attachmentDeletedCount: Int
  public let subjects: [ObservedV19SubjectReview]

  init(
    tableCount: Int, recordCount: UInt64, fieldCount: UInt64, cellCount: UInt64,
    relationshipCount: UInt64, nullCount: UInt64, integerCount: UInt64, realCount: UInt64,
    textCount: UInt64, blobCount: UInt64, subjects: [ObservedV19SubjectReview]
  ) {
    self.tableCount = tableCount
    self.recordCount = recordCount
    self.fieldCount = fieldCount
    self.cellCount = cellCount
    self.relationshipCount = relationshipCount
    tombstoneCount = 0
    tombstoneReasonCode = .tombstoneEncodingUnknown
    self.nullCount = nullCount
    self.integerCount = integerCount
    self.realCount = realCount
    self.textCount = textCount
    self.blobCount = blobCount
    self.subjects = subjects
    subjectCount = subjects.count
    mappedCount = subjects.count { $0.disposition == .mapped }
    preservedCount = subjects.count { $0.disposition == .preserved }
    excludedCount = subjects.count { $0.disposition == .excluded }
    blockedCount = subjects.count { $0.disposition == .blocked }
    let attachmentStates = subjects.compactMap {
      (subject) -> MoneyManagerV19ObservedSchema.AttachmentState? in
      guard subject.kind == .record else { return nil }
      return subject.attachmentState
    }
    attachmentPresentCount = attachmentStates.count { $0 == .present }
    attachmentMissingCount = attachmentStates.count { $0 == .missing }
    attachmentOrphanedCount = attachmentStates.count { $0 == .orphaned }
    attachmentDeletedCount = attachmentStates.count { $0 == .deleted }
  }

  public func jsonData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }

  public var humanDescription: String {
    [
      "tables=\(tableCount)",
      "records=\(recordCount)",
      "fields=\(fieldCount)",
      "cells=\(cellCount)",
      "relationships=\(relationshipCount)",
      "tombstones=\(tombstoneCount)",
      "tombstone_reason=\(tombstoneReasonCode.rawValue)",
      "subjects=\(subjectCount)",
      "mapped=\(mappedCount)",
      "preserved=\(preservedCount)",
      "excluded=\(excludedCount)",
      "blocked=\(blockedCount)",
      "attachment_present=\(attachmentPresentCount)",
      "attachment_missing=\(attachmentMissingCount)",
      "attachment_orphaned=\(attachmentOrphanedCount)",
      "attachment_deleted=\(attachmentDeletedCount)",
    ].joined(separator: "\n")
  }

  public var description: String { humanDescription }
}

extension MoneyManagerV19ObservedSchema {
  public static let maximumReviewTables = 256
  public static let maximumReviewColumns = 4_096
  public static let maximumReviewRecords = StagingLimits.standard.maximumRecords

  public static func publishedRole(for tableName: String) -> ObservedV19SubjectRole? {
    switch tableName {
    case "ASSETS": .account
    case "ZCATEGORY": .category
    case "CURRENCY": .currency
    case "INOUTCOME": .transaction
    case "PHOTO", "SMS_RAW_READ": .attachment
    case "REPEATTRANSACTION": .recurrence
    case "BUDGET", "BUDGET_AMOUNT": .budget
    case "TAG", "TX_TAG": .tag
    case "android_metadata": .metadata
    case "ASSETGROUP", "CODE_DATA", "CODE_LINK", "FAVTRANSACTION", "MEMO", "MESSAGEMACRO2", "ZETC":
      .auxiliary
    default: nil
    }
  }

  /// L0 publishes no certified column alphabet; extra columns stay unknown.
  public static func publishedFieldNames(for tableName: String) -> Set<String> {
    _ = tableName
    return []
  }

  public static func review(databaseURL: URL) throws -> ObservedV19StructureReview {
    try ObservedV19StructureReviewer.review(databaseURL: databaseURL, recordLimit: nil)
  }

  static func review(databaseURL: URL, testingRecordLimit: Int) throws -> ObservedV19StructureReview
  {
    try ObservedV19StructureReviewer.review(
      databaseURL: databaseURL, recordLimit: testingRecordLimit)
  }
}

private enum ObservedV19StructureReviewer {
  static func review(databaseURL: URL, recordLimit: Int?) throws -> ObservedV19StructureReview {
    let url = databaseURL.standardizedFileURL
    var pathBefore = stat()
    guard lstat(url.path, &pathBefore) == 0 else {
      throw MoneyManagerV19ObservedSchemaError.unreadableSource
    }
    let fileType = pathBefore.st_mode & S_IFMT
    guard fileType != S_IFLNK, fileType == S_IFREG else {
      throw MoneyManagerV19ObservedSchemaError.unreadableSource
    }
    guard companionsAbsent(url) else {
      throw MoneyManagerV19ObservedSchemaError.companionFilesPresent
    }
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw MoneyManagerV19ObservedSchemaError.unreadableSource }
    defer { Darwin.close(descriptor) }
    var before = stat()
    guard fstat(descriptor, &before) == 0, sameIdentity(before, pathBefore) else {
      throw MoneyManagerV19ObservedSchemaError.unreadableSource
    }
    let sqliteDescriptor = dup(descriptor)
    guard sqliteDescriptor >= 0 else { throw MoneyManagerV19ObservedSchemaError.unreadableSource }
    defer { Darwin.close(sqliteDescriptor) }
    var database: OpaquePointer?
    guard
      sqlite3_open_v2(
        "file:/dev/fd/\(sqliteDescriptor)?mode=ro&immutable=1", &database,
        SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
      let database
    else {
      if database != nil { sqlite3_close(database) }
      throw MoneyManagerV19ObservedSchemaError.invalidSQLite
    }
    defer { sqlite3_close(database) }
    guard sqlite3_db_readonly(database, "main") == 1,
      execute(database, "PRAGMA query_only=ON"),
      execute(database, "PRAGMA trusted_schema=OFF")
    else { throw MoneyManagerV19ObservedSchemaError.invalidSQLite }
    func validateIdentity() throws {
      var descriptorNow = stat()
      var pathNow = stat()
      guard fstat(descriptor, &descriptorNow) == 0, lstat(url.path, &pathNow) == 0,
        sameIdentity(before, descriptorNow), sameIdentity(before, pathNow),
        companionsAbsent(url)
      else { throw MoneyManagerV19ObservedSchemaError.unreadableSource }
    }
    return try review(database, recordLimit: recordLimit, validateIdentity: validateIdentity)
  }

  private static func review(
    _ database: OpaquePointer, recordLimit: Int?, validateIdentity: () throws -> Void
  ) throws -> ObservedV19StructureReview {
    let present = try listPresentTables(database)
    let maximumRecords = recordLimit ?? MoneyManagerV19ObservedSchema.maximumReviewRecords
    var columnTotal = 0
    var recordTotal: UInt64 = 0
    for table in present {
      let columns = try tableColumns(database, table: table.name)
      let (nextColumns, columnOverflow) = columnTotal.addingReportingOverflow(columns.count)
      guard !columnOverflow,
        nextColumns <= MoneyManagerV19ObservedSchema.maximumReviewColumns
      else { throw MoneyManagerV19ObservedSchemaError.hostileSize }
      columnTotal = nextColumns
      let rows = try rowCount(database, table: table.name)
      let (nextRows, rowOverflow) = recordTotal.addingReportingOverflow(rows)
      guard !rowOverflow, nextRows <= UInt64(maximumRecords) else {
        throw MoneyManagerV19ObservedSchemaError.hostileSize
      }
      recordTotal = nextRows
    }
    try validateIdentity()
    let review = try buildReview(
      database, present: present, columnTotal: columnTotal, recordTotal: recordTotal)
    try validateIdentity()
    return review
  }

  private static func buildReview(
    _ database: OpaquePointer, present: [PresentTable], columnTotal: Int, recordTotal: UInt64
  ) throws -> ObservedV19StructureReview {
    let publishedNames = MoneyManagerV19ObservedSchema.inventory(
      tableNames: MoneyManagerV19ObservedSchema.tableNames)
    guard Set(publishedNames).count == publishedNames.count else {
      throw MoneyManagerV19ObservedSchemaError.invalidSQLite
    }
    let presentNames = present.map(\.name)
    guard Set(presentNames).count == presentNames.count else {
      throw MoneyManagerV19ObservedSchemaError.invalidSQLite
    }
    let presentByName = Dictionary(uniqueKeysWithValues: present.map { ($0.name, $0) })
    let publishedOrdinals = Dictionary(
      uniqueKeysWithValues: publishedNames.enumerated().map { ($1, $0) })
    let unknownNames = MoneyManagerV19ObservedSchema.inventory(
      tableNames: presentNames.filter { MoneyManagerV19ObservedSchema.publishedRole(for: $0) == nil }
    )
    guard Set(unknownNames).count == unknownNames.count else {
      throw MoneyManagerV19ObservedSchemaError.invalidSQLite
    }
    let unknownOrdinals = Dictionary(
      uniqueKeysWithValues: unknownNames.enumerated().map {
        ($1, publishedNames.count + $0)
      })
    var subjects: [ObservedV19SubjectReview] = []
    var totals = StorageCounts()
    var relationships: UInt64 = 0
    subjects.reserveCapacity(publishedNames.count + unknownNames.count + columnTotal)
    for name in publishedNames {
      if let table = presentByName[name] {
        try appendPresentTable(
          database, table: table, ordinal: publishedOrdinals[name]!, subjects: &subjects,
          totals: &totals, relationships: &relationships)
      } else {
        let role = MoneyManagerV19ObservedSchema.publishedRole(for: name) ?? .unknown
        subjects.append(
          ObservedV19SubjectReview(
            subjectID: subjectID(.table, name, recordKey: nil, ordinal: nil, columnName: nil),
            kind: .table, ordinal: publishedOrdinals[name]!, role: role, recordCount: 0,
            fieldCount: 0, nullCount: 0, integerCount: 0, realCount: 0, textCount: 0, blobCount: 0,
            attachmentState: nil, disposition: .blocked, reasonCode: .publishedTableMissing))
      }
    }
    for name in unknownNames {
      guard let table = presentByName[name], let ordinal = unknownOrdinals[name] else {
        throw MoneyManagerV19ObservedSchemaError.invalidSQLite
      }
      try appendPresentTable(
        database, table: table, ordinal: ordinal, subjects: &subjects, totals: &totals,
        relationships: &relationships)
    }
    subjects.sort {
      if $0.kind != $1.kind { return $0.kind.sortOrdinal < $1.kind.sortOrdinal }
      if $0.ordinal != $1.ordinal { return $0.ordinal < $1.ordinal }
      return $0.subjectID < $1.subjectID
    }
    var cellCount: UInt64 = 0
    guard increment(&cellCount, totals.nullCount), increment(&cellCount, totals.integerCount),
      increment(&cellCount, totals.realCount), increment(&cellCount, totals.textCount),
      increment(&cellCount, totals.blobCount)
    else { throw MoneyManagerV19ObservedSchemaError.invalidSQLite }
    return ObservedV19StructureReview(
      tableCount: publishedNames.count + unknownNames.count, recordCount: recordTotal,
      fieldCount: UInt64(columnTotal), cellCount: cellCount, relationshipCount: relationships,
      nullCount: totals.nullCount, integerCount: totals.integerCount, realCount: totals.realCount,
      textCount: totals.textCount, blobCount: totals.blobCount, subjects: subjects)
  }

  private static func appendPresentTable(
    _ database: OpaquePointer, table: PresentTable, ordinal: Int,
    subjects: inout [ObservedV19SubjectReview], totals: inout StorageCounts,
    relationships: inout UInt64
  ) throws {
    let columns = try tableColumns(database, table: table.name)
    let role = MoneyManagerV19ObservedSchema.publishedRole(for: table.name) ?? .unknown
    let tableDisposition = disposition(for: role)
    let tableReason = reasonCode(for: role)
    let usesImplicitRowid = table.usesImplicitRowid(columns: columns)
    let inspected = try inspectTable(
      database, table: table.name, columns: columns, role: role, disposition: tableDisposition,
      reason: tableReason, emitRecordSubjects: usesImplicitRowid)
    guard totals.add(inspected.tableStorage) else {
      throw MoneyManagerV19ObservedSchemaError.invalidSQLite
    }
    let foreignKeys = try foreignKeyCount(database, table: table.name)
    guard increment(&relationships, foreignKeys) else {
      throw MoneyManagerV19ObservedSchemaError.invalidSQLite
    }
    subjects.append(
      ObservedV19SubjectReview(
        subjectID: subjectID(.table, table.name, recordKey: nil, ordinal: nil, columnName: nil),
        kind: .table, ordinal: ordinal, role: role, recordCount: inspected.recordCount,
        fieldCount: UInt64(columns.count), nullCount: inspected.tableStorage.nullCount,
        integerCount: inspected.tableStorage.integerCount,
        realCount: inspected.tableStorage.realCount, textCount: inspected.tableStorage.textCount,
        blobCount: inspected.tableStorage.blobCount, attachmentState: inspected.tableAttachment,
        disposition: tableDisposition, reasonCode: tableReason))
    subjects.append(contentsOf: inspected.records)
    let publishedTable = MoneyManagerV19ObservedSchema.publishedRole(for: table.name) != nil
    for (index, column) in columns.enumerated() {
      let storage = inspected.columnStorage[index]
      let fieldRole = publishedTable ? role : .unknown
      let fieldDisposition = disposition(for: fieldRole)
      let fieldReason =
        publishedTable ? ObservedV19ReviewReasonCode.columnAlphabetUncertified : .unknownSubjectPreserved
      subjects.append(
        ObservedV19SubjectReview(
          subjectID: subjectID(
            .field, table.name, recordKey: nil, ordinal: column.ordinal, columnName: column.name),
          kind: .field, ordinal: column.ordinal, role: fieldRole,
          recordCount: inspected.recordCount, fieldCount: 1, nullCount: storage.nullCount,
          integerCount: storage.integerCount, realCount: storage.realCount,
          textCount: storage.textCount, blobCount: storage.blobCount, attachmentState: nil,
          disposition: fieldDisposition, reasonCode: fieldReason))
    }
  }

  private static func inspectTable(
    _ database: OpaquePointer, table: String, columns: [TableColumn], role: ObservedV19SubjectRole,
    disposition: ObservedV19SubjectDisposition, reason: ObservedV19ReviewReasonCode,
    emitRecordSubjects: Bool
  ) throws -> TableInspection {
    var tableStorage = StorageCounts()
    var columnStorage = Array(repeating: StorageCounts(), count: columns.count)
    var records: [ObservedV19SubjectReview] = []
    let recordCount = try rowCount(database, table: table)
    var tableAttachment: MoneyManagerV19ObservedSchema.AttachmentState?
    if columns.isEmpty || recordCount == 0 {
      return TableInspection(
        recordCount: recordCount, tableStorage: tableStorage, columnStorage: columnStorage,
        records: [], tableAttachment: nil)
    }
    if !emitRecordSubjects {
      for (index, column) in columns.enumerated() {
        columnStorage[index] = try storageClassCounts(database, table: table, column: column.name)
        guard tableStorage.add(columnStorage[index]) else {
          throw MoneyManagerV19ObservedSchemaError.invalidSQLite
        }
      }
      return TableInspection(
        recordCount: recordCount, tableStorage: tableStorage, columnStorage: columnStorage,
        records: [], tableAttachment: nil)
    }
    let typeList = columns.map { "typeof(\(quotedIdentifier($0.name)))" }.joined(separator: ",")
    let sql = "SELECT rowid, \(typeList) FROM \(quotedIdentifier(table)) ORDER BY rowid"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw MoneyManagerV19ObservedSchemaError.invalidSQLite
    }
    defer { sqlite3_finalize(statement) }
    var recordOrdinal = 0
    try forEachRow(statement) {
      guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER else {
        throw MoneyManagerV19ObservedSchemaError.invalidSQLite
      }
      let rowid = sqlite3_column_int64(statement, 0)
      var rowStorage = StorageCounts()
      var storageClasses: [String] = []
      storageClasses.reserveCapacity(columns.count)
      for index in columns.indices {
        guard let storage = strictText(statement, column: Int32(index + 1)) else {
          throw MoneyManagerV19ObservedSchemaError.invalidSQLite
        }
        storageClasses.append(storage)
        guard rowStorage.add(storage), tableStorage.add(storage),
          columnStorage[index].add(storage)
        else { throw MoneyManagerV19ObservedSchemaError.invalidSQLite }
      }
      let attachment = attachmentState(table: table, storageClasses: storageClasses)
      if let attachment {
        tableAttachment = mergedAttachmentState(tableAttachment, attachment)
      }
      records.append(
        ObservedV19SubjectReview(
          subjectID: subjectID(
            .record, table, recordKey: String(rowid), ordinal: nil, columnName: nil),
          kind: .record, ordinal: recordOrdinal, role: role, recordCount: 1,
          fieldCount: UInt64(columns.count), nullCount: rowStorage.nullCount,
          integerCount: rowStorage.integerCount, realCount: rowStorage.realCount,
          textCount: rowStorage.textCount, blobCount: rowStorage.blobCount,
          attachmentState: attachment, disposition: disposition, reasonCode: reason))
      recordOrdinal += 1
    }
    guard UInt64(records.count) == recordCount else {
      throw MoneyManagerV19ObservedSchemaError.invalidSQLite
    }
    return TableInspection(
      recordCount: recordCount, tableStorage: tableStorage, columnStorage: columnStorage,
      records: records, tableAttachment: tableAttachment)
  }

  // L0: only PHOTO payload presence is classified; orphaned/deleted stay unused.
  private static func attachmentState(
    table: String, storageClasses: [String]
  ) -> MoneyManagerV19ObservedSchema.AttachmentState? {
    guard table == "PHOTO" else { return nil }
    return storageClasses.contains("blob") ? .present : .missing
  }

  private static func mergedAttachmentState(
    _ current: MoneyManagerV19ObservedSchema.AttachmentState?,
    _ next: MoneyManagerV19ObservedSchema.AttachmentState
  ) -> MoneyManagerV19ObservedSchema.AttachmentState {
    switch (current, next) {
    case (nil, let next): next
    case (.present, _), (_, .present): .present
    case (.missing, .missing): .missing
    default: next
    }
  }

  private static func disposition(for role: ObservedV19SubjectRole) -> ObservedV19SubjectDisposition
  {
    switch role {
    case .metadata: .excluded
    case .unknown: .preserved
    case .account, .category, .currency, .transaction, .attachment, .recurrence, .budget, .tag,
      .auxiliary:
      .preserved
    }
  }

  private static func reasonCode(for role: ObservedV19SubjectRole) -> ObservedV19ReviewReasonCode {
    switch role {
    case .metadata: .adapterMetadataTable
    case .unknown: .unknownSubjectPreserved
    case .account, .category, .currency, .transaction, .attachment, .recurrence, .budget, .tag,
      .auxiliary:
      .publishedStructurePreserved
    }
  }

  private static func subjectID(
    _ kind: ObservedV19SubjectKind, _ tableName: String, recordKey: String?, ordinal: Int?,
    columnName: String?
  ) -> String {
    StableStagingID.digest([
      "ledger-atlas/observed-v19/\(kind.rawValue)/v1",
      tableName,
      recordKey ?? "",
      ordinal.map(String.init) ?? "",
      columnName ?? "",
    ])
  }

  private static func listPresentTables(_ database: OpaquePointer) throws -> [PresentTable] {
    let counted = try scalarUInt64(
      database,
      """
      SELECT count(*) FROM sqlite_schema
      WHERE type='table' AND name NOT LIKE 'sqlite_%'
      """)
    guard counted <= UInt64(MoneyManagerV19ObservedSchema.maximumReviewTables) else {
      throw MoneyManagerV19ObservedSchemaError.hostileSize
    }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA table_list", -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw MoneyManagerV19ObservedSchemaError.invalidSQLite }
    defer { sqlite3_finalize(statement) }
    var tables: [PresentTable] = []
    var seen: Set<String> = []
    try forEachRow(statement) {
      guard let schema = strictText(statement, column: 0),
        let name = strictText(statement, column: 1),
        let type = strictText(statement, column: 2),
        sqlite3_column_type(statement, 4) == SQLITE_INTEGER
      else { throw MoneyManagerV19ObservedSchemaError.invalidSQLite }
      guard schema == "main", !name.hasPrefix("sqlite_") else { return }
      if type == "virtual" { throw MoneyManagerV19ObservedSchemaError.invalidSQLite }
      guard tables.count < MoneyManagerV19ObservedSchema.maximumReviewTables else {
        throw MoneyManagerV19ObservedSchemaError.hostileSize
      }
      guard seen.insert(name).inserted else {
        throw MoneyManagerV19ObservedSchemaError.invalidSQLite
      }
      tables.append(
        PresentTable(name: name, withoutRowid: sqlite3_column_int64(statement, 4) == 1))
    }
    guard tables.count == counted else {
      throw MoneyManagerV19ObservedSchemaError.invalidSQLite
    }
    return tables
  }

  private static func tableColumns(_ database: OpaquePointer, table: String) throws -> [TableColumn]
  {
    let sql = "PRAGMA table_xinfo(\(quotedIdentifier(table)))"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw MoneyManagerV19ObservedSchemaError.invalidSQLite
    }
    defer { sqlite3_finalize(statement) }
    var columns: [TableColumn] = []
    var ordinal = 0
    try forEachRow(statement) {
      guard let name = strictText(statement, column: 1),
        sqlite3_column_type(statement, 6) == SQLITE_INTEGER
      else { throw MoneyManagerV19ObservedSchemaError.invalidSQLite }
      // hidden != 0 is a generated or virtual column; typeof() would evaluate it.
      guard sqlite3_column_int64(statement, 6) == 0 else {
        throw MoneyManagerV19ObservedSchemaError.invalidSQLite
      }
      columns.append(TableColumn(ordinal: ordinal, name: name))
      ordinal += 1
    }
    return columns
  }

  private static func rowCount(_ database: OpaquePointer, table: String) throws -> UInt64 {
    try scalarUInt64(database, "SELECT COUNT(*) FROM \(quotedIdentifier(table))")
  }

  private static func foreignKeyCount(_ database: OpaquePointer, table: String) throws -> UInt64 {
    let sql = "PRAGMA foreign_key_list(\(quotedIdentifier(table)))"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw MoneyManagerV19ObservedSchemaError.invalidSQLite
    }
    defer { sqlite3_finalize(statement) }
    var count: UInt64 = 0
    try forEachRow(statement) {
      guard increment(&count, 1) else { throw MoneyManagerV19ObservedSchemaError.invalidSQLite }
    }
    return count
  }

  private static func storageClassCounts(
    _ database: OpaquePointer, table: String, column: String
  ) throws -> StorageCounts {
    let sql =
      "SELECT typeof(\(quotedIdentifier(column))), COUNT(*) FROM \(quotedIdentifier(table)) GROUP BY 1"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw MoneyManagerV19ObservedSchemaError.invalidSQLite
    }
    defer { sqlite3_finalize(statement) }
    var counts = StorageCounts()
    try forEachRow(statement) {
      guard let storage = strictText(statement, column: 0),
        sqlite3_column_type(statement, 1) == SQLITE_INTEGER
      else { throw MoneyManagerV19ObservedSchemaError.invalidSQLite }
      let value = sqlite3_column_int64(statement, 1)
      guard value >= 0, counts.add(storage, count: UInt64(value)) else {
        throw MoneyManagerV19ObservedSchemaError.invalidSQLite
      }
    }
    return counts
  }

  private static func execute(_ database: OpaquePointer, _ sql: String) -> Bool {
    sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
  }

  private static func scalarUInt64(_ database: OpaquePointer, _ sql: String) throws -> UInt64 {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw MoneyManagerV19ObservedSchemaError.invalidSQLite
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
      sqlite3_column_type(statement, 0) == SQLITE_INTEGER
    else { throw MoneyManagerV19ObservedSchemaError.invalidSQLite }
    let value = sqlite3_column_int64(statement, 0)
    guard value >= 0, sqlite3_step(statement) == SQLITE_DONE else {
      throw MoneyManagerV19ObservedSchemaError.invalidSQLite
    }
    return UInt64(value)
  }

  private static func forEachRow(_ statement: OpaquePointer, _ body: () throws -> Void) throws {
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        try body()
      case SQLITE_DONE:
        return
      default:
        throw MoneyManagerV19ObservedSchemaError.invalidSQLite
      }
    }
  }

  private static func strictText(_ statement: OpaquePointer, column: Int32) -> String? {
    guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
      let bytes = sqlite3_column_text(statement, column)
    else { return nil }
    let count = Int(sqlite3_column_bytes(statement, column))
    guard count >= 0 else { return nil }
    let data = Data(bytes: bytes, count: count)
    guard !data.contains(0), let value = String(data: data, encoding: .utf8) else { return nil }
    return value
  }

  private static func quotedIdentifier(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
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
}

private struct PresentTable {
  let name: String
  let withoutRowid: Bool

  func usesImplicitRowid(columns: [TableColumn]) -> Bool {
    !withoutRowid
      && !columns.contains { $0.name.caseInsensitiveCompare("rowid") == .orderedSame }
  }
}

private struct TableColumn {
  let ordinal: Int
  let name: String
}

private struct TableInspection {
  let recordCount: UInt64
  let tableStorage: StorageCounts
  let columnStorage: [StorageCounts]
  let records: [ObservedV19SubjectReview]
  let tableAttachment: MoneyManagerV19ObservedSchema.AttachmentState?
}

private struct StorageCounts {
  var nullCount: UInt64 = 0
  var integerCount: UInt64 = 0
  var realCount: UInt64 = 0
  var textCount: UInt64 = 0
  var blobCount: UInt64 = 0

  mutating func add(_ storage: String, count: UInt64 = 1) -> Bool {
    switch storage {
    case "null": increment(&nullCount, count)
    case "integer": increment(&integerCount, count)
    case "real": increment(&realCount, count)
    case "text": increment(&textCount, count)
    case "blob": increment(&blobCount, count)
    default: false
    }
  }

  mutating func add(_ other: StorageCounts) -> Bool {
    increment(&nullCount, other.nullCount) && increment(&integerCount, other.integerCount)
      && increment(&realCount, other.realCount) && increment(&textCount, other.textCount)
      && increment(&blobCount, other.blobCount)
  }
}

private func increment(_ value: inout UInt64, _ amount: UInt64) -> Bool {
  let (sum, overflow) = value.addingReportingOverflow(amount)
  guard !overflow else { return false }
  value = sum
  return true
}
