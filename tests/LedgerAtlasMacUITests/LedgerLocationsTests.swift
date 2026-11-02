import Foundation
import Testing

@testable import LedgerAtlasMacUI

@Test func ledgerStorageIsOwnerOnlyAndNamesAreSafeAndUnique() throws {
  let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: base) }
  let directory = try LedgerLocations.ledgersDirectory(base: base)
  #expect(directory.path.hasSuffix("Ledger Atlas/Ledgers"))
  let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
  #expect((mode as? NSNumber)?.intValue == 0o700)

  #expect(LedgerLocations.fileStem(for: "  Household 2026 ") == "Household 2026")
  #expect(LedgerLocations.fileStem(for: "../../etc/passwd") == "etcpasswd")
  #expect(LedgerLocations.fileStem(for: "///") == "Ledger")

  let first = LedgerLocations.availableURL(named: "Home", in: directory)
  #expect(first.lastPathComponent == "Home.sqlite")
  try Data("x".utf8).write(to: first)
  let second = LedgerLocations.availableURL(named: "Home", in: directory)
  #expect(second.lastPathComponent == "Home 2.sqlite")
  #expect(LedgerLocations.isInside(second, directory))
  #expect(!LedgerLocations.isInside(base.appendingPathComponent("Home.sqlite"), directory))
  // Files in app storage need no security scope.
  #expect(LedgerLocations.startAccess(first, ledgersDirectory: directory))
}

@Test func openingALedgerFromElsewhereCopiesItAndLeavesTheOriginal() throws {
  let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: base) }
  let directory = try LedgerLocations.ledgersDirectory(base: base)
  let outside = base.appendingPathComponent("Downloads", isDirectory: true)
  try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
  let source = outside.appendingPathComponent("Shared ledger.sqlite")
  let bytes = Data((0..<4096).map { UInt8($0 % 251) })
  try bytes.write(to: source)

  let copy = try LedgerLocations.importCopy(of: source, into: directory)

  #expect(copy.lastPathComponent == "Shared ledger.sqlite")
  #expect(LedgerLocations.isInside(copy, directory))
  #expect(try Data(contentsOf: copy) == bytes)
  #expect(try Data(contentsOf: source) == bytes)
  let mode = try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions]
  #expect((mode as? NSNumber)?.intValue == 0o600)
  // A second copy of the same file gets a new name instead of replacing the first.
  #expect(
    try LedgerLocations.importCopy(of: source, into: directory).lastPathComponent
      == "Shared ledger 2.sqlite")
}
