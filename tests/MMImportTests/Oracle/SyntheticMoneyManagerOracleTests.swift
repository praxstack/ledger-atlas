import CSQLite
import CryptoKit
import Foundation
import Testing

@testable import MMImport

@Suite("Synthetic Money Manager oracle")
struct SyntheticMoneyManagerOracleTests {
  @Test("reports one action, structural diffs, and content-free evidence")
  func reportsStructuralDiffWithoutCellValuesOrPaths() throws {
    try withOracleDirectory { directory in
      let before = directory.appendingPathComponent("before.sqlite")
      let after = directory.appendingPathComponent("after.sqlite")
      try makeDatabase(at: before, rows: 1, includeExtraColumn: false, secret: "before-private-value")
      try makeDatabase(at: after, rows: 2, includeExtraColumn: true, secret: "after-private-value")
      let beforeHash = try sha256(before)
      let afterHash = try sha256(after)

      let report = try SyntheticMoneyManagerOracle.compare(
        before: before, after: after, action: try .init(identifier: "add-three-category-purchase"))
      let output = String(decoding: try report.jsonData(), as: UTF8.self)

      #expect(report.action.identifier == "add-three-category-purchase")
      #expect(report.before.sha256 == beforeHash)
      #expect(report.after.sha256 == afterHash)
      #expect(report.differences.contains { $0.kind == .changed })
      #expect(!output.contains("before-private-value"))
      #expect(!output.contains("after-private-value"))
      #expect(!output.contains(before.path))
      #expect(!output.contains(after.path))
      #expect(try sha256(before) == beforeHash)
      #expect(try sha256(after) == afterHash)
    }
  }

  @Test("digests every source-controlled schema identifier and rejects invalid actions")
  func digestsIdentifiersAndRejectsInvalidActions() throws {
    try withOracleDirectory { directory in
      let before = directory.appendingPathComponent("before.sqlite")
      let after = directory.appendingPathComponent("after.sqlite")
      try makeDatabase(at: before, rows: 1, includeExtraColumn: false, secret: "safe")
      try makeDatabase(at: after, rows: 1, includeExtraColumn: false, secret: "safe")
      try execute(at: after, "CREATE TABLE \"private-name\" (\"private-column\" TEXT)")
      try execute(at: after, "CREATE TABLE Alice (MedicalCondition TEXT)")

      let report = try SyntheticMoneyManagerOracle.compare(
        before: before, after: after, action: try .init(identifier: "add-table"))
      let output = String(decoding: try report.jsonData(), as: UTF8.self)
      #expect(!output.contains("private-name"))
      #expect(!output.contains("private-column"))
      #expect(!output.contains("Alice"))
      #expect(!output.contains("MedicalCondition"))
      #expect(report.differences.contains { $0.subject.hasPrefix("sha256:") })
      #expect(throws: SyntheticMoneyManagerOracleError.invalidAction) {
        _ = try OracleAction(identifier: "contains private words")
      }
      #expect(throws: SyntheticMoneyManagerOracleError.invalidAction) {
        _ = try JSONDecoder().decode(OracleAction.self, from: Data("\"contains private words\"".utf8))
      }
    }
  }

  @Test("fails closed for non SQLite, companions, and bounds")
  func rejectsUnsafeInputsAndBounds() throws {
    try withOracleDirectory { directory in
      let invalid = directory.appendingPathComponent("invalid.sqlite")
      try Data("not a database".utf8).write(to: invalid)
      #expect(throws: SyntheticMoneyManagerOracleError.invalidSQLite) {
        _ = try SyntheticMoneyManagerOracle.compare(
          before: invalid, after: invalid, action: try .init(identifier: "invalid"))
      }

      let source = directory.appendingPathComponent("source.sqlite")
      try makeDatabase(at: source, rows: 1, includeExtraColumn: false, secret: "safe")
      try Data().write(to: URL(fileURLWithPath: source.path + "-wal"))
      #expect(throws: SyntheticMoneyManagerOracleError.companionFilesPresent) {
        _ = try SyntheticMoneyManagerOracle.compare(
          before: source, after: source, action: try .init(identifier: "companions"))
      }
      try FileManager.default.removeItem(at: URL(fileURLWithPath: source.path + "-wal"))

      #expect(throws: SyntheticMoneyManagerOracleError.hostileSize) {
        _ = try SyntheticMoneyManagerOracle.compare(
          before: source, after: source, action: try .init(identifier: "bounds"),
          limits: .init(maximumBytes: 1, maximumTables: 8, maximumColumns: 8, maximumRows: 8))
      }
      #expect(throws: SyntheticMoneyManagerOracleError.hostileSize) {
        _ = try SyntheticMoneyManagerOracle.compare(
          before: source, after: source, action: try .init(identifier: "column-bounds"),
          limits: .init(maximumBytes: 1_024_024, maximumTables: 8, maximumColumns: 1, maximumRows: 8))
      }
    }
  }

  @Test("schema object evidence catches type constraint order index trigger and view changes")
  func schemaObjectEvidenceCatchesEveryDDLChange() throws {
    try withOracleDirectory { directory in
      let baseline = directory.appendingPathComponent("baseline.sqlite")
      try execute(at: baseline, "CREATE TABLE Alice (id INTEGER PRIMARY KEY, amount TEXT)")
      let variants = [
        "CREATE TABLE Alice (id INTEGER PRIMARY KEY, amount BLOB)",
        "CREATE TABLE Alice (amount TEXT, id INTEGER PRIMARY KEY)",
        "CREATE TABLE Alice (id INTEGER PRIMARY KEY, amount TEXT NOT NULL CHECK(length(amount) > 0))",
        "CREATE TABLE Alice (id INTEGER PRIMARY KEY, amount TEXT); CREATE INDEX private_index ON Alice(amount)",
        "CREATE TABLE Alice (id INTEGER PRIMARY KEY, amount TEXT); CREATE TRIGGER private_trigger AFTER INSERT ON Alice BEGIN SELECT 1; END",
        "CREATE TABLE Alice (id INTEGER PRIMARY KEY, amount TEXT); CREATE VIEW private_view AS SELECT id FROM Alice",
      ]
      for (index, ddl) in variants.enumerated() {
        let changed = directory.appendingPathComponent("changed-\(index).sqlite")
        try execute(at: changed, ddl)
        let report = try SyntheticMoneyManagerOracle.compare(
          before: baseline, after: changed, action: try .init(identifier: "schema-change-\(index)"))
        #expect(report.before.schemaSHA256 != report.after.schemaSHA256)
        #expect(!report.differences.isEmpty)
        let output = String(decoding: try report.jsonData(), as: UTF8.self)
        #expect(!output.contains("Alice"))
        #expect(!output.contains("private_index"))
        #expect(!output.contains("private_trigger"))
        #expect(!output.contains("private_view"))
      }
    }
  }

  @Test("WAL appearance path replacement and growth after final hash fail closed")
  func sourceChangesAfterFinalHashFailClosed() throws {
    try withOracleDirectory { directory in
      for mutation in OracleMutation.allCases {
        let source = directory.appendingPathComponent("\(mutation.rawValue).sqlite")
        try makeDatabase(at: source, rows: 1, includeExtraColumn: false, secret: "safe")
        let state = OracleMutationState()
        #expect(throws: mutation.expectedError) {
          var ran = false
          _ = try SyntheticMoneyManagerOracle.compare(
            before: source, after: source, action: try .init(identifier: mutation.rawValue),
            limits: .standard,
            testingAfterFinalHash: {
              guard !ran else { return }
              ran = true
              do { try mutation.apply(to: source, directory: directory) }
              catch { state.error = error }
            })
        }
        #expect(state.error == nil)
      }
    }
  }

  @Test("same-inode growth after open is rejected before source fingerprinting")
  func sourceGrowthAfterOpenFailsClosed() throws {
    try withOracleDirectory { directory in
      let source = directory.appendingPathComponent("source.sqlite")
      try makeDatabase(at: source, rows: 1, includeExtraColumn: false, secret: "safe")
      guard let initialBytes = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber else {
        throw OracleTestError.sqlite
      }
      let limits = OracleLimits(
        maximumBytes: initialBytes.uint64Value, maximumTables: 8, maximumColumns: 8, maximumRows: 8)
      var ran = false

      #expect(throws: SyntheticMoneyManagerOracleError.hostileSize) {
        _ = try SyntheticMoneyManagerOracle.compare(
          before: source, after: source, action: try .init(identifier: "grow-after-open"), limits: limits,
          testingAfterOpen: {
            guard !ran else { return }
            ran = true
            let handle = try! FileHandle(forWritingTo: source)
            defer { try? handle.close() }
            try! handle.seekToEnd()
            try! handle.write(contentsOf: Data([0]))
          })
      }
      #expect(ran)
    }
  }
}

private final class OracleMutationState {
  var error: Error?
}

private enum OracleMutation: String, CaseIterable {
  case wal, replacement, growth

  var expectedError: SyntheticMoneyManagerOracleError {
    self == .wal ? .companionFilesPresent : .sourceChanged
  }

  func apply(to source: URL, directory: URL) throws {
    switch self {
    case .wal:
      try Data().write(to: URL(fileURLWithPath: source.path + "-wal"))
    case .replacement:
      let replacement = directory.appendingPathComponent("replacement-candidate.sqlite")
      try makeDatabase(at: replacement, rows: 2, includeExtraColumn: false, secret: "replacement")
      try FileManager.default.removeItem(at: source)
      try FileManager.default.copyItem(at: replacement, to: source)
    case .growth:
      let handle = try FileHandle(forWritingTo: source)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: Data([0]))
    }
  }
}

private func withOracleDirectory(_ body: (URL) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try body(directory)
}

private func makeDatabase(at url: URL, rows: Int, includeExtraColumn: Bool, secret: String) throws {
  var database: OpaquePointer?
  guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else { throw OracleTestError.sqlite }
  defer { sqlite3_close(database) }
  try execute(database, "CREATE TABLE ZCATEGORY (id INTEGER PRIMARY KEY, name TEXT\(includeExtraColumn ? ", extra TEXT" : ""))")
  for index in 0..<rows {
    try execute(database, "INSERT INTO ZCATEGORY (id, name\(includeExtraColumn ? ", extra" : "")) VALUES (\(index), '\(secret)'\(includeExtraColumn ? ", 'extra'" : ""))")
  }
}

private func execute(at url: URL, _ sql: String) throws {
  var database: OpaquePointer?
  guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else { throw OracleTestError.sqlite }
  defer { sqlite3_close(database) }
  try execute(database, sql)
}

private func execute(_ database: OpaquePointer, _ sql: String) throws {
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw OracleTestError.sqlite }
}

private func sha256(_ url: URL) throws -> String {
  SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

private enum OracleTestError: Error { case sqlite }
