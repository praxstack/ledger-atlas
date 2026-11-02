// Sandbox file-access probe. Run sandboxed (see sandbox-probe.sh) with a grant for exactly
// one file path, the way a save panel grants a path to the shipped app. It reports which of
// the ledger's file operations the sandbox allows next to that path.
import Foundation
import SQLite3

let granted = URL(fileURLWithPath: CommandLine.arguments[1])
let grantedDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
var results: [(String, Bool, String)] = []

func record(_ name: String, _ body: () throws -> Void) {
  do {
    try body()
    results.append((name, true, ""))
  } catch {
    results.append((name, false, "\(error)"))
  }
}

struct Failure: Error, CustomStringConvertible {
  let description: String
}

func create(_ path: String) throws {
  let fd = open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
  guard fd >= 0 else { throw Failure(description: "errno \(errno) \(String(cString: strerror(errno)))") }
  close(fd)
}

record("create the granted file") { try create(granted.path) }
record("write the granted file") { try Data("x".utf8).write(to: granted) }
record("create sibling <name>-journal") { try create(granted.path + "-journal") }
record("create sibling .tmp in the same folder") {
  try create(granted.deletingLastPathComponent().appendingPathComponent(".probe.tmp").path)
}
record("create sibling <name>.sha256") { try create(granted.path + ".sha256") }
record("itemReplacementDirectory temp + replaceItemAt the granted file") {
  let scratch = try FileManager.default.url(
    for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: granted, create: true)
  let temp = scratch.appendingPathComponent("probe.tmp")
  try Data("replaced".utf8).write(to: temp)
  _ = try FileManager.default.replaceItemAt(granted, withItemAt: temp)
  guard try String(contentsOf: granted, encoding: .utf8) == "replaced" else {
    throw Failure(description: "content not replaced")
  }
}
record("sqlite: create table + insert in the granted file (rollback journal)") {
  try? FileManager.default.removeItem(at: granted)
  var db: OpaquePointer?
  guard sqlite3_open_v2(granted.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK
  else { throw Failure(description: "open: \(String(cString: sqlite3_errmsg(db)))") }
  defer { sqlite3_close(db) }
  for sql in ["CREATE TABLE t(x)", "BEGIN", "INSERT INTO t VALUES(1)", "COMMIT"] {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      throw Failure(description: "\(sql): \(String(cString: sqlite3_errmsg(db)))")
    }
  }
}
record("granted folder: create, write, rename inside it") {
  let temp = grantedDirectory.appendingPathComponent(".backup.tmp")
  try create(temp.path)
  try Data("y".utf8).write(to: temp)
  guard rename(temp.path, grantedDirectory.appendingPathComponent("ledger.sqlite").path) == 0
  else { throw Failure(description: "rename errno \(errno)") }
}
record("granted folder: sqlite with journal") {
  var db: OpaquePointer?
  let path = grantedDirectory.appendingPathComponent("folder.sqlite").path
  guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK
  else { throw Failure(description: "open: \(String(cString: sqlite3_errmsg(db)))") }
  defer { sqlite3_close(db) }
  for sql in ["CREATE TABLE t(x)", "BEGIN", "INSERT INTO t VALUES(1)", "COMMIT"] {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      throw Failure(description: "\(sql): \(String(cString: sqlite3_errmsg(db)))")
    }
  }
}
record("control: write outside any grant is denied") {
  let outside = NSHomeDirectory() + "/../../../probe-outside-\(getpid())"
  do { try create(outside) } catch { return }
  throw Failure(description: "unexpectedly allowed (sandbox not active?)")
}

print("| Operation | Allowed | Detail |\n|---|---|---|")
for (name, ok, detail) in results { print("| \(name) | \(ok ? "yes" : "NO") | \(detail) |") }
