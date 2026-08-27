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
      #expect(report.differences.contains { $0.kind == .changed && $0.subject == "ZCATEGORY" })
      #expect(!output.contains("before-private-value"))
      #expect(!output.contains("after-private-value"))
      #expect(!output.contains(before.path))
      #expect(!output.contains(after.path))
      #expect(try sha256(before) == beforeHash)
      #expect(try sha256(after) == afterHash)
    }
  }

  @Test("redacts unsafe schema identifiers and rejects invalid action identifiers")
  func redactsUnsafeIdentifiersAndRejectsInvalidActions() throws {
    try withOracleDirectory { directory in
      let before = directory.appendingPathComponent("before.sqlite")
      let after = directory.appendingPathComponent("after.sqlite")
      try makeDatabase(at: before, rows: 1, includeExtraColumn: false, secret: "safe")
      try makeDatabase(at: after, rows: 1, includeExtraColumn: false, secret: "safe")
      try execute(at: after, "CREATE TABLE \"private-name\" (\"private-column\" TEXT)")

      let report = try SyntheticMoneyManagerOracle.compare(
        before: before, after: after, action: try .init(identifier: "add-table"))
      let output = String(decoding: try report.jsonData(), as: UTF8.self)
      #expect(!output.contains("private-name"))
      #expect(!output.contains("private-column"))
      #expect(report.differences.contains { $0.subject.hasPrefix("sha256:") })
      #expect(throws: SyntheticMoneyManagerOracleError.invalidAction) {
        _ = try OracleAction(identifier: "contains private words")
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
