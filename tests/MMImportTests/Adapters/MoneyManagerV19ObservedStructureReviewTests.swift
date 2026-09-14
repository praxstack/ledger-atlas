import CSQLite
import Darwin
import Foundation
import LedgerCore
import Testing

@testable import MMImport

@Suite("Observed v19 structure review")
struct ObservedV19StructureReviewTests {
  @Test("observedV19 empty published tables are counted, stable, and never mapped")
  func observedV19EmptyPublishedTablesAreCountedAndNeverMapped() throws {
    try withObservedV19ReviewDirectory { directory in
      let source = directory.appendingPathComponent("published-empty.sqlite")
      try createPublishedObservedV19Database(at: source)
      let before = try fileIdentity(source)

      let first = try MoneyManagerV19ObservedSchema.review(databaseURL: source)
      let second = try MoneyManagerV19ObservedSchema.review(databaseURL: source)
      let tableSubjects = first.subjects.filter { $0.kind == .table }
      let fieldSubjects = first.subjects.filter { $0.kind == .field }
      let ordered = MoneyManagerV19ObservedSchema.inventory(
        tableNames: MoneyManagerV19ObservedSchema.tableNames)
      let roles = Dictionary(grouping: tableSubjects, by: \.role).mapValues(\.count)
      let surfaces = try reviewSurfaces(first)

      #expect(first.tableCount == 19)
      #expect(tableSubjects.count == 19)
      #expect(fieldSubjects.count == 19)
      #expect(fieldSubjects.allSatisfy { $0.role != .unknown })
      #expect(fieldSubjects.allSatisfy { $0.reasonCode == .columnAlphabetUncertified })
      #expect(first.cellCount == 0)
      #expect(first.relationshipCount == 0)
      #expect(first.tombstoneCount == 0)
      #expect(first.tombstoneReasonCode == .tombstoneEncodingUnknown)
      #expect(first.mappedCount == 0)
      #expect(first.attachmentOrphanedCount == 0)
      #expect(first.attachmentDeletedCount == 0)
      #expect(tableSubjects.map(\.ordinal).sorted() == Array(0..<19))
      #expect(tableSubjects.allSatisfy { CanonicalIdentifier.isValid($0.subjectID) })
      #expect(first.subjects.allSatisfy { $0.disposition != .mapped })
      #expect(roles[.account] == 1)
      #expect(roles[.category] == 1)
      #expect(roles[.currency] == 1)
      #expect(roles[.transaction] == 1)
      #expect(roles[.attachment] == 2)
      #expect(roles[.recurrence] == 1)
      #expect(roles[.budget] == 2)
      #expect(roles[.tag] == 2)
      #expect(roles[.auxiliary] == 7)
      #expect(roles[.metadata] == 1)
      #expect(roles[.unknown] == nil)
      #expect(
        tableSubjects.filter { $0.role == .metadata }.allSatisfy { $0.disposition == .excluded })
      for (ordinal, name) in ordered.enumerated() {
        let subject = try #require(tableSubjects.first { $0.ordinal == ordinal })
        #expect(subject.role == MoneyManagerV19ObservedSchema.publishedRole(for: name))
        #expect(!surfaces.contains(name))
      }
      #expect(!surfaces.contains("locator"))
      #expect(first.subjects.map(\.subjectID) == second.subjects.map(\.subjectID))
      #expect(first.tableCount == second.tableCount)
      #expect(first.recordCount == second.recordCount)
      #expect(first.fieldCount == second.fieldCount)
      #expect(first.cellCount == second.cellCount)
      #expect(try fileIdentity(source) == before)
    }
  }

  @Test("observedV19 PHOTO locator is classified without leaking the locator")
  func observedV19PhotoLocatorHasExplicitAttachmentState() throws {
    try withObservedV19ReviewDirectory { directory in
      let locator = "synthetic-ref"
      let source = directory.appendingPathComponent("do-not-leak-source-path.sqlite")
      try createPublishedObservedV19Database(at: source, photoLocator: locator)

      let review = try MoneyManagerV19ObservedSchema.review(databaseURL: source)
      let attachmentRecords = review.subjects.filter {
        $0.kind == .record && $0.role == .attachment
      }
      let surfaces = try reviewSurfaces(review)

      #expect(attachmentRecords.count == 1)
      #expect(attachmentRecords[0].attachmentState == .missing)
      #expect(review.textCount == 1)
      #expect(review.blobCount == 0)
      #expect(review.cellCount == 1)
      #expect(review.attachmentMissingCount == 1)
      #expect(review.attachmentPresentCount == 0)
      #expect(review.attachmentOrphanedCount == 0)
      #expect(review.attachmentDeletedCount == 0)
      #expect(!surfaces.contains(locator))
      #expect(!surfaces.contains(source.path))
      #expect(!surfaces.contains("do-not-leak-source-path"))
      #expect(!surfaces.contains("locator"))
    }
  }

  @Test("observedV19 PHOTO blob is present without emitting payload bytes")
  func observedV19PhotoBlobIsPresentWithoutPayloadBytes() throws {
    try withObservedV19ReviewDirectory { directory in
      let locator = "synthetic-ref"
      let source = directory.appendingPathComponent("photo-blob.sqlite")
      try createPublishedObservedV19Database(
        at: source, photoLocator: locator, photoBlobBytes: 1)

      let review = try MoneyManagerV19ObservedSchema.review(databaseURL: source)
      let attachmentRecords = review.subjects.filter {
        $0.kind == .record && $0.role == .attachment
      }
      let surfaces = try reviewSurfaces(review)

      #expect(attachmentRecords.count == 1)
      #expect(attachmentRecords[0].attachmentState == .present)
      #expect(review.blobCount == 1)
      #expect(review.attachmentPresentCount == 1)
      #expect(review.attachmentMissingCount == 0)
      #expect(review.attachmentOrphanedCount == 0)
      #expect(review.attachmentDeletedCount == 0)
      #expect(!surfaces.contains(locator))
      #expect(!surfaces.contains("payload"))
    }
  }

  @Test("observedV19 unknown table is preserved or blocked without leaking its name")
  func observedV19UnknownTableIsNotMappedOrNamed() throws {
    try withObservedV19ReviewDirectory { directory in
      let source = directory.appendingPathComponent("unknown-table.sqlite")
      try createPublishedObservedV19Database(at: source, extraTableNames: ["hostile_name"])

      let review = try MoneyManagerV19ObservedSchema.review(databaseURL: source)
      let unknownTables = review.subjects.filter { $0.kind == .table && $0.role == .unknown }
      let surfaces = try reviewSurfaces(review)

      #expect(review.tableCount == 20)
      #expect(unknownTables.count == 1)
      #expect(unknownTables[0].disposition == .preserved || unknownTables[0].disposition == .blocked)
      #expect(unknownTables[0].disposition != .mapped)
      #expect(review.subjects.contains { $0.kind == .field && $0.role == .unknown })
      #expect(!surfaces.contains("hostile_name"))
    }
  }

  @Test("observedV19 extra published-table column is unnamed and counted")
  func observedV19ExtraColumnIsUnnamedAndCounted() throws {
    try withObservedV19ReviewDirectory { directory in
      let baseline = directory.appendingPathComponent("extra-column-baseline.sqlite")
      let source = directory.appendingPathComponent("extra-column.sqlite")
      try createPublishedObservedV19Database(at: baseline)
      try createPublishedObservedV19Database(
        at: source, extraColumns: [("ASSETS", "hostile_column")])

      let baselineReview = try MoneyManagerV19ObservedSchema.review(databaseURL: baseline)
      let review = try MoneyManagerV19ObservedSchema.review(databaseURL: source)
      let baselineFields = baselineReview.subjects.filter { $0.kind == .field }
      let fields = review.subjects.filter { $0.kind == .field }
      let surfaces = try reviewSurfaces(review)

      #expect(fields.count == baselineFields.count + 1)
      #expect(review.fieldCount == baselineReview.fieldCount + 1)
      #expect(fields.allSatisfy { $0.role != .unknown })
      #expect(fields.contains { $0.reasonCode == .columnAlphabetUncertified })
      #expect(!surfaces.contains("hostile_column"))
      #expect(!surfaces.contains("ASSETS"))
    }
  }

  @Test("observedV19 missing published table is a blocked subject")
  func observedV19MissingPublishedTableIsBlocked() throws {
    try withObservedV19ReviewDirectory { directory in
      let source = directory.appendingPathComponent("missing-published.sqlite")
      try createPublishedObservedV19Database(at: source, omittedPublished: ["ZETC"])

      let review = try MoneyManagerV19ObservedSchema.review(databaseURL: source)
      let tableSubjects = review.subjects.filter { $0.kind == .table }
      let blocked = tableSubjects.filter { $0.disposition == .blocked }
      let surfaces = try reviewSurfaces(review)

      #expect(review.tableCount == 19)
      #expect(tableSubjects.count == 19)
      #expect(blocked.count == 1)
      #expect(blocked[0].reasonCode == .publishedTableMissing)
      #expect(blocked[0].role == .auxiliary)
      #expect(review.blockedCount == 1)
      #expect(!surfaces.contains("ZETC"))
    }
  }

  @Test("observedV19 WITHOUT ROWID extra table still reviews")
  func observedV19WithoutRowidExtraTableStillReviews() throws {
    try withObservedV19ReviewDirectory { directory in
      let source = directory.appendingPathComponent("without-rowid.sqlite")
      try createPublishedObservedV19Database(at: source, withoutRowidTable: "hostile_without_rowid")

      let review = try MoneyManagerV19ObservedSchema.review(databaseURL: source)
      let unknownTables = review.subjects.filter { $0.kind == .table && $0.role == .unknown }
      let surfaces = try reviewSurfaces(review)

      #expect(review.tableCount == 20)
      #expect(unknownTables.count == 1)
      #expect(unknownTables[0].recordCount == 1)
      #expect(review.subjects.contains { $0.kind == .record && $0.role == .unknown } == false)
      #expect(!surfaces.contains("hostile_without_rowid"))
    }
  }

  @Test("observedV19 hostile size fails closed before allocating a review")
  func observedV19HostileSizeFailsClosed() throws {
    try withObservedV19ReviewDirectory { directory in
      let tooManyTables = directory.appendingPathComponent("too-many-tables.sqlite")
      try createSQLite(at: tooManyTables) { database in
        for index in 0...MoneyManagerV19ObservedSchema.maximumReviewTables {
          try execute(
            database,
            "CREATE TABLE t\(String(format: "%03d", index)) (id INTEGER)")
        }
      }
      #expect(throws: MoneyManagerV19ObservedSchemaError.hostileSize) {
        _ = try MoneyManagerV19ObservedSchema.review(databaseURL: tooManyTables)
      }

      let tooManyColumns = directory.appendingPathComponent("too-many-columns.sqlite")
      try createSQLite(at: tooManyColumns) { database in
        let columns = (0..<1_400).map { "c\($0) INTEGER" }.joined(separator: ",")
        for index in 0..<3 {
          try execute(database, "CREATE TABLE w\(index) (\(columns))")
        }
      }
      #expect(throws: MoneyManagerV19ObservedSchemaError.hostileSize) {
        _ = try MoneyManagerV19ObservedSchema.review(databaseURL: tooManyColumns)
      }

      let tooManyRecords = directory.appendingPathComponent("too-many-records.sqlite")
      let testRecordLimit = 8
      try createSQLite(at: tooManyRecords) { database in
        try execute(database, "CREATE TABLE t(id INTEGER PRIMARY KEY)")
        try execute(database, "INSERT INTO t(id) VALUES (1)")
        var count = 1
        let limit = testRecordLimit + 1
        while count < limit {
          try execute(
            database,
            "INSERT INTO t(id) SELECT id+\(count) FROM t WHERE id+\(count) <= \(limit)")
          count *= 2
        }
      }
      #expect(MoneyManagerV19ObservedSchema.maximumReviewRecords == 2_000_000)
      #expect(throws: MoneyManagerV19ObservedSchemaError.hostileSize) {
        _ = try MoneyManagerV19ObservedSchema.review(
          databaseURL: tooManyRecords, testingRecordLimit: testRecordLimit)
      }
    }
  }

  @Test("observedV19 virtual generated columns fail closed")
  func observedV19VirtualGeneratedColumnsFailClosed() throws {
    try withObservedV19ReviewDirectory { directory in
      let source = directory.appendingPathComponent("generated-virtual.sqlite")
      try createPublishedObservedV19Database(at: source)
      try createSQLite(at: source) { database in
        try execute(
          database,
          """
          CREATE TABLE generated_hostile (
            id INTEGER,
            g TEXT GENERATED ALWAYS AS (hex(zeroblob(1048576))) VIRTUAL
          )
          """)
      }

      #expect(throws: MoneyManagerV19ObservedSchemaError.invalidSQLite) {
        _ = try MoneyManagerV19ObservedSchema.review(databaseURL: source)
      }
    }
  }

  @Test("observedV19 unsafe sources fail closed without hanging")
  func observedV19UnsafeSourcesFailClosed() throws {
    try withObservedV19ReviewDirectory { directory in
      let missing = directory.appendingPathComponent("missing.sqlite")
      #expect(throws: MoneyManagerV19ObservedSchemaError.unreadableSource) {
        _ = try MoneyManagerV19ObservedSchema.review(databaseURL: missing)
      }

      let source = directory.appendingPathComponent("regular.sqlite")
      try createPublishedObservedV19Database(at: source)

      let link = directory.appendingPathComponent("link.sqlite")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
      #expect(throws: MoneyManagerV19ObservedSchemaError.unreadableSource) {
        _ = try MoneyManagerV19ObservedSchema.review(databaseURL: link)
      }

      let fifo = directory.appendingPathComponent("fifo.sqlite")
      guard mkfifo(fifo.path, 0o600) == 0 else { throw ReviewTestFailure.sqlite }
      #expect(throws: MoneyManagerV19ObservedSchemaError.unreadableSource) {
        _ = try MoneyManagerV19ObservedSchema.review(databaseURL: fifo)
      }

      let companion = directory.appendingPathComponent("companion.sqlite")
      try createPublishedObservedV19Database(at: companion)
      #expect(
        FileManager.default.createFile(
          atPath: companion.path + "-wal", contents: Data()))
      #expect(throws: MoneyManagerV19ObservedSchemaError.companionFilesPresent) {
        _ = try MoneyManagerV19ObservedSchema.review(databaseURL: companion)
      }

      #expect(chmod(source.path, 0) == 0)
      defer { _ = chmod(source.path, S_IRUSR | S_IWUSR) }
      #expect(throws: MoneyManagerV19ObservedSchemaError.unreadableSource) {
        _ = try MoneyManagerV19ObservedSchema.review(databaseURL: source)
      }
    }
  }

  @Test("observedV19 repeat review of unchanged bytes keeps subject IDs and counts")
  func observedV19RepeatReviewIsStable() throws {
    try withObservedV19ReviewDirectory { directory in
      let source = directory.appendingPathComponent("repeat-review.sqlite")
      try createPublishedObservedV19Database(
        at: source, extraTableNames: ["hostile_name"], photoLocator: "synthetic-ref")

      let first = try MoneyManagerV19ObservedSchema.review(databaseURL: source)
      let second = try MoneyManagerV19ObservedSchema.review(databaseURL: source)

      #expect(first == second)
      #expect(first.subjects.map(\.subjectID) == second.subjects.map(\.subjectID))
      #expect(first.tableCount == second.tableCount)
      #expect(first.recordCount == second.recordCount)
      #expect(first.fieldCount == second.fieldCount)
      #expect(first.cellCount == second.cellCount)
      #expect(first.subjects.count == second.subjects.count)
    }
  }
}

private enum ReviewTestFailure: Error { case sqlite }

private func reviewSurfaces(_ review: ObservedV19StructureReview) throws -> String {
  let json = String(decoding: try review.jsonData(), as: UTF8.self)
  return [json, review.humanDescription, String(describing: review)].joined(separator: "\n")
}

private func fileIdentity(_ url: URL) throws -> (Int64, Int, Int) {
  var value = stat()
  guard lstat(url.path, &value) == 0 else { throw ReviewTestFailure.sqlite }
  return (Int64(value.st_size), Int(value.st_mtimespec.tv_sec), Int(value.st_mtimespec.tv_nsec))
}

private func withObservedV19ReviewDirectory(_ body: (URL) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "ledger-atlas-observed-v19-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: directory) }
  try body(directory)
}

private func createPublishedObservedV19Database(
  at url: URL, extraTableNames: [String] = [], photoLocator: String? = nil,
  photoBlobBytes: Int? = nil, omittedPublished: Set<String> = [],
  extraColumns: [(String, String)] = [], withoutRowidTable: String? = nil
) throws {
  let extras = Dictionary(grouping: extraColumns, by: \.0).mapValues { $0.map(\.1) }
  try createSQLite(at: url) { database in
    for name in MoneyManagerV19ObservedSchema.tableNames {
      guard !omittedPublished.contains(name) else { continue }
      if name == "PHOTO", let photoLocator {
        if photoBlobBytes != nil {
          try execute(database, "CREATE TABLE \"PHOTO\" (locator TEXT, payload BLOB)")
          var statement: OpaquePointer?
          guard
            sqlite3_prepare_v2(
              database, "INSERT INTO \"PHOTO\" (locator, payload) VALUES (?, zeroblob(?))",
              -1, &statement, nil) == SQLITE_OK,
            let statement
          else { throw ReviewTestFailure.sqlite }
          defer { sqlite3_finalize(statement) }
          let inserted = photoLocator.withCString { pointer in
            sqlite3_bind_text(statement, 1, pointer, -1, nil) == SQLITE_OK
              && sqlite3_bind_int64(statement, 2, Int64(photoBlobBytes ?? 0)) == SQLITE_OK
              && sqlite3_step(statement) == SQLITE_DONE
          }
          guard inserted else { throw ReviewTestFailure.sqlite }
        } else {
          try execute(database, "CREATE TABLE \"PHOTO\" (locator TEXT)")
          var statement: OpaquePointer?
          guard
            sqlite3_prepare_v2(
              database, "INSERT INTO \"PHOTO\" (locator) VALUES (?)", -1, &statement, nil)
              == SQLITE_OK,
            let statement
          else { throw ReviewTestFailure.sqlite }
          defer { sqlite3_finalize(statement) }
          let inserted = photoLocator.withCString { pointer in
            sqlite3_bind_text(statement, 1, pointer, -1, nil) == SQLITE_OK
              && sqlite3_step(statement) == SQLITE_DONE
          }
          guard inserted else { throw ReviewTestFailure.sqlite }
        }
      } else {
        let added = extras[name, default: []].map { "\(quoteSQLIdentifier($0)) TEXT" }
        let columnSQL = (["id INTEGER"] + added).joined(separator: ", ")
        try execute(database, "CREATE TABLE \(quoteSQLIdentifier(name)) (\(columnSQL))")
      }
    }
    for name in extraTableNames {
      try execute(database, "CREATE TABLE \(quoteSQLIdentifier(name)) (value TEXT)")
    }
    if let withoutRowidTable {
      try execute(
        database,
        """
        CREATE TABLE \(quoteSQLIdentifier(withoutRowidTable)) (
          key TEXT PRIMARY KEY, value TEXT
        ) WITHOUT ROWID
        """)
      try execute(
        database,
        "INSERT INTO \(quoteSQLIdentifier(withoutRowidTable)) VALUES ('synthetic-key', 'synthetic-value')"
      )
    }
  }
}

private func createSQLite(at url: URL, _ body: (OpaquePointer) throws -> Void) throws {
  var database: OpaquePointer?
  guard
    sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
      == SQLITE_OK,
    let database
  else { throw ReviewTestFailure.sqlite }
  defer { sqlite3_close(database) }
  try body(database)
}

private func execute(_ database: OpaquePointer, _ sql: String) throws {
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
    throw ReviewTestFailure.sqlite
  }
}

private func quoteSQLIdentifier(_ value: String) -> String {
  "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
}
