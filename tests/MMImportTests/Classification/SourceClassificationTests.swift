import CSQLite
import Darwin
import Foundation
import Testing

@testable import MMImport

@Suite("Immutable source classification")
struct SourceClassificationTests {
  @Test("direct SQLite is detected by bytes and remains unchanged")
  func directSQLiteMMBakIsImmutable() throws {
    try withTemporaryDirectory { directory in
      let source = directory.appendingPathComponent("synthetic.mmbak")
      try createSyntheticDatabase(at: source, sentinel: "PRIVATE_SENTINEL_MUST_NOT_APPEAR")
      let profile = try syntheticProfile(for: source)
      let before = try attributes(source)

      let result = SourceClassifier(profiles: [profile]).classify(source)

      #expect(result.container == .sqlite)
      #expect(result.status == .supported)
      #expect(result.profile == profile)
      #expect(result.fingerprintBefore == result.fingerprintAfter)
      let after = try attributes(source)
      #expect(before.size == after.size)
      #expect(before.modified == after.modified)
    }
  }

  @Test("explicit coverage collects aggregate storage shapes without values")
  func explicitCoverageCollectsAggregateShapes() throws {
    try withTemporaryDirectory { directory in
      let source = directory.appendingPathComponent("coverage.sqlite")
      try createSyntheticDatabase(at: source, sentinel: "PRIVATE_COVERAGE_VALUE")
      let profile = try syntheticProfile(for: source)
      let result = SourceClassifier(profiles: [profile], collectStructuralCoverage: true)
        .classify(source)
      let coverage = try #require(result.metadata?.structuralCoverage)
      #expect(coverage.recordCount == 1)
      #expect(coverage.fieldCount == 2)
      #expect(coverage.integerCount == 1)
      #expect(coverage.textCount == 1)
      #expect(coverage.nullCount == 0)
      #expect(coverage.realCount == 0)
      #expect(coverage.blobCount == 0)
    }
  }

  @Test("wrong extension cannot override SQLite magic")
  func wrongExtensionUsesContent() throws {
    try withTemporaryDirectory { directory in
      let source = directory.appendingPathComponent("synthetic.zip")
      try createSyntheticDatabase(at: source)
      let profile = try syntheticProfile(for: source)
      #expect(SourceClassifier(profiles: [profile]).classify(source).container == .sqlite)
    }
  }

  @Test("unknown and drifted schemas fail closed")
  func unknownAndDriftedSchemas() throws {
    try withTemporaryDirectory { directory in
      let source = directory.appendingPathComponent("unknown.sqlite")
      try createSyntheticDatabase(at: source)
      let initial = SourceClassifier(profiles: []).classify(source)
      #expect(initial.status == .unsupported)
      #expect(initial.diagnostics == [.unknownProfile])
      let profile = try syntheticProfile(for: source)
      try executeSQLite(source, "ALTER TABLE synthetic_entries ADD COLUMN drifted TEXT")
      let drifted = SourceClassifier(profiles: [profile], collectStructuralCoverage: true)
        .classify(source)
      #expect(drifted.status == .unsupported)
      #expect(drifted.diagnostics == [.schemaDrift])
      #expect(drifted.metadata?.structuralCoverage != nil)
    }
  }

  @Test("NUL-suffixed sqlite_schema SQL changes the exact schema fingerprint")
  func nulSuffixedSchemaSQLIsSchemaDrift() throws {
    try withTemporaryDirectory { directory in
      let source = directory.appendingPathComponent("nul-schema.sqlite")
      try createSyntheticDatabase(at: source)
      let profile = try syntheticProfile(for: source)
      #expect(SourceClassifier(profiles: [profile]).classify(source).status == .supported)

      try appendNULSuffixToSchemaSQL(source, object: "synthetic_entries")

      let drifted = SourceClassifier(profiles: [profile]).classify(source)
      #expect(drifted.status == .unsupported)
      #expect(drifted.diagnostics == [.schemaDrift])
    }
  }

  @Test("invalid, truncated, and companion-bearing inputs are loud")
  func invalidTruncatedAndCompanions() throws {
    try withTemporaryDirectory { directory in
      let truncated = directory.appendingPathComponent("truncated.mmbak")
      try Data("SQLite format 3\0".utf8).write(to: truncated)
      let corrupt = SourceClassifier().classify(truncated)
      #expect(corrupt.status == .corrupt)
      #expect(corrupt.diagnostics == [.truncatedInput])

      let opaque = directory.appendingPathComponent("opaque.sqlite")
      try Data([0, 1, 2]).write(to: opaque)
      let unsupported = SourceClassifier().classify(opaque)
      #expect(unsupported.status == .unsupported)
      #expect(unsupported.diagnostics == [.unsupportedContainer])

      let database = directory.appendingPathComponent("companion.sqlite")
      try createSyntheticDatabase(at: database)
      try Data().write(to: URL(fileURLWithPath: database.path + "-wal"))
      try Data().write(to: URL(fileURLWithPath: database.path + "-journal"))
      let incomplete = SourceClassifier().classify(database)
      #expect(incomplete.status == .incomplete)
      #expect(incomplete.diagnostics == [.companionFiles])
      #expect(incomplete.fingerprintBefore == incomplete.fingerprintAfter)
    }
  }

  @Test("SQLite companion appearance and disappearance fail closed")
  func sqliteCompanionRaceFailsClosed() throws {
    try withTemporaryDirectory { directory in
      let appearingSource = directory.appendingPathComponent("appearing.sqlite")
      try createSyntheticDatabase(at: appearingSource)
      let profile = try syntheticProfile(for: appearingSource)
      let wal = URL(fileURLWithPath: appearingSource.path + "-wal")
      let appeared = SourceClassifier(
        profiles: [profile],
        testingBeforeFinalFingerprint: {
          FileManager.default.createFile(atPath: wal.path, contents: Data())
        }
      ).classify(appearingSource)
      #expect(appeared.status == .incomplete)
      #expect(appeared.diagnostics == [.sourceChanged])

      let disappearingSource = directory.appendingPathComponent("disappearing.sqlite")
      try createSyntheticDatabase(at: disappearingSource)
      let shm = URL(fileURLWithPath: disappearingSource.path + "-shm")
      try Data().write(to: shm)
      let disappeared = SourceClassifier(
        testingBeforeFinalFingerprint: {
          try? FileManager.default.removeItem(at: shm)
        }
      ).classify(disappearingSource)
      #expect(disappeared.status == .incomplete)
      #expect(disappeared.diagnostics == [.sourceChanged])
    }
  }

  @Test("missing, unreadable, symlink, and nonregular inputs are distinct")
  func sourceTypeAndAccessDiagnostics() throws {
    try withTemporaryDirectory { directory in
      let missing = directory.appendingPathComponent("missing")
      let missingResult = SourceClassifier().classify(missing)
      #expect(missingResult.status == .unavailable)
      #expect(missingResult.diagnostics == [.fileNotFound])
      #expect(missingResult.suggestedExitCode == 2)

      let source = directory.appendingPathComponent("source.sqlite")
      try createSyntheticDatabase(at: source)
      let link = directory.appendingPathComponent("source-link.sqlite")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
      let linkResult = SourceClassifier().classify(link)
      #expect(linkResult.status == .unsupported)
      #expect(linkResult.diagnostics == [.sourceSymlink])

      let nonregular = SourceClassifier().classify(directory)
      #expect(nonregular.status == .unsupported)
      #expect(nonregular.diagnostics == [.sourceNotRegular])

      #expect(chmod(source.path, 0) == 0)
      defer { _ = chmod(source.path, S_IRUSR | S_IWUSR) }
      let unreadable = SourceClassifier().classify(source)
      #expect(unreadable.status == .unavailable)
      #expect(unreadable.diagnostics == [.fileUnreadable])
      #expect(unreadable.suggestedExitCode == 4)
    }
  }

  @Test("fingerprints bind identity, nanosecond mtime, and hardlink mutation")
  func fingerprintIdentityAndMutation() throws {
    try withTemporaryDirectory { directory in
      let source = directory.appendingPathComponent("source.sqlite")
      try createSyntheticDatabase(at: source)
      let profile = try syntheticProfile(for: source)
      let stable = SourceClassifier(profiles: [profile]).classify(source)
      let fingerprint = try #require(stable.fingerprintBefore)
      #expect(fingerprint.deviceID > 0)
      #expect(fingerprint.inode > 0)
      #expect(fingerprint.modificationTimeNanoseconds >= 0)

      let alias = directory.appendingPathComponent("alias.sqlite")
      try FileManager.default.linkItem(at: source, to: alias)
      let changed = SourceClassifier(
        profiles: [profile],
        testingBeforeFinalFingerprint: {
          let descriptor = open(alias.path, O_WRONLY | O_APPEND)
          if descriptor >= 0 {
            var byte: UInt8 = 0
            _ = Darwin.write(descriptor, &byte, 1)
            _ = close(descriptor)
          }
        }
      ).classify(source)
      #expect(changed.status == .incomplete)
      #expect(changed.diagnostics == [.sourceChanged])
      #expect(changed.fingerprintBefore != changed.fingerprintAfter)
    }
  }

  @Test("path replacement and metadata-only mutation fail closed")
  func replacementAndMtimeMutation() throws {
    try withTemporaryDirectory { directory in
      let source = directory.appendingPathComponent("source.sqlite")
      try createSyntheticDatabase(at: source)
      let profile = try syntheticProfile(for: source)
      let replacement = directory.appendingPathComponent("replacement.sqlite")
      try createSyntheticDatabase(at: replacement, sentinel: "replacement")
      let replaced = SourceClassifier(
        profiles: [profile],
        testingBeforeFinalFingerprint: {
          _ = rename(replacement.path, source.path)
        }
      ).classify(source)
      #expect(replaced.status == .incomplete)
      #expect(replaced.diagnostics == [.sourceChanged])

      let metadataSource = directory.appendingPathComponent("mtime.sqlite")
      try createSyntheticDatabase(at: metadataSource)
      let metadataProfile = try syntheticProfile(for: metadataSource)
      let mtimeChanged = SourceClassifier(
        profiles: [metadataProfile],
        testingBeforeFinalFingerprint: {
          var times = [
            timespec(tv_sec: 1_800_000_000, tv_nsec: 123_456_789),
            timespec(tv_sec: 1_800_000_000, tv_nsec: 123_456_789),
          ]
          _ = utimensat(AT_FDCWD, metadataSource.path, &times, 0)
        }
      ).classify(metadataSource)
      #expect(mtimeChanged.status == .incomplete)
      #expect(mtimeChanged.diagnostics == [.sourceChanged])
    }
  }

  @Test("stored and deflated ZIP32 members fail closed without a writable source copy")
  func storedAndDeflatedZIP() throws {
    try withTemporaryDirectory { directory in
      let database = directory.appendingPathComponent("payload.bin")
      try createSyntheticDatabase(at: database)
      let profile = try syntheticProfile(for: database)
      let bytes = try Data(contentsOf: database)

      let stored = directory.appendingPathComponent("stored.opaque")
      try makeStoredZIP(entries: [("member.data", bytes)], at: stored)
      let storedResult = SourceClassifier(profiles: [profile]).classify(stored)
      #expect(storedResult.container == .zip)
      #expect(storedResult.status == .supported)
      #expect(storedResult.profile == profile)
      #expect(storedResult.fingerprintBefore == storedResult.fingerprintAfter)

      let deflated = directory.appendingPathComponent("deflated.mmbak")
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
      process.arguments = ["-q", "-j", deflated.path, database.path]
      try process.run()
      process.waitUntilExit()
      #expect(process.terminationStatus == 0)
      let deflatedResult = SourceClassifier(profiles: [profile]).classify(deflated)
      #expect(deflatedResult.container == .zip)
      #expect(deflatedResult.status == .supported)
      #expect(deflatedResult.profile == profile)
    }
  }

  @Test("archived SQLite companions block a supported classification")
  func archivedSQLiteCompanions() throws {
    try withTemporaryDirectory { directory in
      let database = directory.appendingPathComponent("database")
      try createSyntheticDatabase(at: database)
      let profile = try syntheticProfile(for: database)
      let bytes = try Data(contentsOf: database)
      let archive = directory.appendingPathComponent("companions.zip")
      try makeStoredZIP(
        entries: [
          ("nested/data.sqlite", bytes),
          ("nested/data.sqlite-wal", Data([1, 2, 3])),
          ("nested/data.sqlite-shm", Data([4, 5, 6])),
        ], at: archive)

      let result = SourceClassifier(profiles: [profile]).classify(archive)
      #expect(result.container == .zip)
      #expect(result.status == .incomplete)
      #expect(result.diagnostics == [.archivedCompanionFiles])
      #expect(result.fingerprintBefore == result.fingerprintAfter)
    }
  }

  @Test("ZIP traversal and normalized duplicates are rejected")
  func zipPathSafety() throws {
    try withTemporaryDirectory { directory in
      let bytes = Data("not sqlite".utf8)
      let traversal = directory.appendingPathComponent("traversal.zip")
      try makeStoredZIP(entries: [("../escape", bytes)], at: traversal)
      #expect(SourceClassifier().classify(traversal).diagnostics == [.unsafeZIPPath])
      #expect(
        !FileManager.default.fileExists(
          atPath: directory.deletingLastPathComponent()
            .appendingPathComponent("escape").path))

      let duplicate = directory.appendingPathComponent("duplicates.zip")
      try makeStoredZIP(entries: [("a/./db", bytes), ("a/db", bytes)], at: duplicate)
      #expect(SourceClassifier().classify(duplicate).diagnostics == [.duplicateZIPName])
    }
  }

  @Test("ZIP CRC, candidate cardinality, and resource bounds fail closed")
  func zipIntegrityAndBounds() throws {
    try withTemporaryDirectory { directory in
      let database = directory.appendingPathComponent("database")
      try createSyntheticDatabase(at: database)
      let bytes = try Data(contentsOf: database)

      let badCRC = directory.appendingPathComponent("bad-crc.zip")
      try makeStoredZIP(entries: [("db", bytes)], at: badCRC, corruptCRC: true)
      #expect(SourceClassifier().classify(badCRC).diagnostics == [.zipCRCFailed])

      let duplicateCandidates = directory.appendingPathComponent("two.zip")
      try makeStoredZIP(entries: [("one", bytes), ("two", bytes)], at: duplicateCandidates)
      #expect(
        SourceClassifier().classify(duplicateCandidates).diagnostics
          == [.duplicateSQLiteCandidates])

      let bounded = directory.appendingPathComponent("bounded.zip")
      try makeStoredZIP(entries: [("db", bytes)], at: bounded)
      let limits = try ZIPInspectionLimits(
        maximumArchiveBytes: bounded.fileSize + 1,
        maximumEntries: 1,
        maximumTotalUncompressedBytes: bytes.count,
        maximumMemberBytes: bytes.count - 1,
        maximumCompressionRatio: 1)
      #expect(
        SourceClassifier(zipLimits: limits).classify(bounded).diagnostics == [.zipBoundsExceeded])
    }
  }

  @Test("ZIP local metadata must match the central directory")
  func zipLocalCentralMismatchAndDescriptor() throws {
    try withTemporaryDirectory { directory in
      let database = directory.appendingPathComponent("database")
      try createSyntheticDatabase(at: database)
      let bytes = try Data(contentsOf: database)

      for fieldOffset in [6, 8, 14, 18, 22] {
        let archive = directory.appendingPathComponent("mismatch-\(fieldOffset).zip")
        try makeStoredZIP(entries: [("db", bytes)], at: archive)
        try mutateZIP(archive) { data in data[fieldOffset] ^= 1 }
        #expect(SourceClassifier().classify(archive).diagnostics == [.malformedZIP])
      }

      let name = directory.appendingPathComponent("name-mismatch.zip")
      try makeStoredZIP(entries: [("db", bytes)], at: name)
      try mutateZIP(name) { data in data[30] = UInt8(ascii: "x") }
      #expect(SourceClassifier().classify(name).diagnostics == [.malformedZIP])

      let descriptor = directory.appendingPathComponent("descriptor.zip")
      try makeStoredZIP(entries: [("db", bytes)], at: descriptor)
      try mutateZIP(descriptor) { data in
        data[6] |= 0x08
        let central = data.firstOffset(of: 0x0201_4b50)!
        data[central + 8] |= 0x08
      }
      #expect(
        SourceClassifier().classify(descriptor).diagnostics
          == [.unsupportedZIPDataDescriptor])
    }
  }

  @Test("ZIP payload overlap, directory payloads, and extensions fail closed")
  func zipStructureAndUnsupportedFeatures() throws {
    try withTemporaryDirectory { directory in
      let bytes = Data("payload".utf8)

      let overlap = directory.appendingPathComponent("overlap.zip")
      try makeStoredZIP(entries: [("one", bytes), ("two", bytes)], at: overlap)
      try mutateZIP(overlap) { data in
        let centrals = data.offsets(of: 0x0201_4b50)
        data.replaceLE32(at: centrals[1] + 42, with: 0)
      }
      #expect(SourceClassifier().classify(overlap).diagnostics == [.zipStructureOverlap])

      let directoryPayload = directory.appendingPathComponent("directory.zip")
      try makeStoredZIP(entries: [("dir/", bytes)], at: directoryPayload)
      #expect(SourceClassifier().classify(directoryPayload).diagnostics == [.malformedZIP])

      let zip64 = directory.appendingPathComponent("zip64.zip")
      try makeStoredZIP(entries: [("db", bytes)], at: zip64)
      try mutateZIP(zip64) { data in
        let central = data.firstOffset(of: 0x0201_4b50)!
        data.replaceLE32(at: central + 20, with: .max)
      }
      #expect(SourceClassifier().classify(zip64).diagnostics == [.unsupportedZIP64])

      let encrypted = directory.appendingPathComponent("encrypted.zip")
      try makeStoredZIP(entries: [("db", bytes)], at: encrypted)
      try mutateZIP(encrypted) { data in
        data[6] |= 1
        let central = data.firstOffset(of: 0x0201_4b50)!
        data[central + 8] |= 1
      }
      #expect(SourceClassifier().classify(encrypted).diagnostics == [.encryptedZIP])

      let multidisk = directory.appendingPathComponent("multidisk.zip")
      try makeStoredZIP(entries: [("db", bytes)], at: multidisk)
      try mutateZIP(multidisk) { data in
        let eocd = data.firstOffset(of: 0x0605_4b50)!
        data[eocd + 4] = 1
      }
      #expect(SourceClassifier().classify(multidisk).diagnostics == [.multidiskZIP])

      let symlink = directory.appendingPathComponent("symlink.zip")
      try makeStoredZIP(entries: [("link", Data())], at: symlink, unixMode: 0o120777)
      #expect(SourceClassifier().classify(symlink).diagnostics == [.symlinkZIPEntry])
    }
  }

  @Test("deflate rejects empty and trailing compressed input")
  func deflateCompleteness() throws {
    try withTemporaryDirectory { directory in
      let empty = directory.appendingPathComponent("empty")
      try Data().write(to: empty)
      let archive = directory.appendingPathComponent("empty.zip")
      try runZIP(input: empty, output: archive)
      #expect(SourceClassifier().classify(archive).diagnostics == [.noSQLiteCandidate])

      let database = directory.appendingPathComponent("database")
      try createSyntheticDatabase(at: database)
      let trailing = directory.appendingPathComponent("trailing.zip")
      try runZIP(input: database, output: trailing)
      try appendTrailingCompressedByte(to: trailing)
      #expect(SourceClassifier().classify(trailing).diagnostics == [.malformedZIP])
    }
  }

  @Test("ZIP limits require positive finite values")
  func zipLimitValidation() {
    #expect(throws: ZIPLimitError.self) {
      try ZIPInspectionLimits(maximumCompressionRatio: .infinity)
    }
    #expect(throws: ZIPLimitError.self) {
      try ZIPInspectionLimits(maximumEntries: 0)
    }
    #expect(throws: ZIPLimitError.self) {
      try ZIPInspectionLimits(maximumCompressionRatio: .nan)
    }
  }

  @Test("redacted report cannot expose paths, schema names, member names, prose, or rows")
  func reportIsRedacted() throws {
    try withTemporaryDirectory { directory in
      let sentinel = "PRIVATE_SENTINEL_MUST_NOT_APPEAR"
      let source = directory.appendingPathComponent("\(sentinel).sqlite")
      try createSyntheticDatabase(at: source, sentinel: sentinel)
      let report = RedactedClassificationReport(SourceClassifier().classify(source))
      let json = String(decoding: try report.jsonData(), as: UTF8.self)
      let human = report.humanDescription
      for output in [json, human] {
        #expect(!output.contains(sentinel))
        #expect(!output.contains(source.path))
        #expect(!output.contains("synthetic_entries"))
        #expect(!output.contains("member.data"))
      }
      #expect(report.reportVersion == 2)
      #expect(SourceClassifier(profiles: []).classify(source).suggestedExitCode == 3)
      #expect(SourceClassifier().classify(directory).suggestedExitCode == 2)
    }
  }
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "ledger-atlas-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: directory) }
  try body(directory)
}

private func createSyntheticDatabase(at url: URL, sentinel: String = "synthetic") throws {
  var database: OpaquePointer?
  guard
    sqlite3_open_v2(
      url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
    let database
  else { throw TestFailure.sqlite }
  defer { sqlite3_close(database) }
  guard sqlite3_exec(database, "PRAGMA user_version=19", nil, nil, nil) == SQLITE_OK,
    sqlite3_exec(
      database,
      "CREATE TABLE synthetic_entries(id INTEGER PRIMARY KEY, note TEXT NOT NULL)",
      nil, nil, nil) == SQLITE_OK,
    sqlite3_exec(
      database, "CREATE INDEX synthetic_note_index ON synthetic_entries(note)", nil, nil, nil)
      == SQLITE_OK
  else { throw TestFailure.sqlite }
  var statement: OpaquePointer?
  guard
    sqlite3_prepare_v2(
      database, "INSERT INTO synthetic_entries(note) VALUES (?)", -1, &statement, nil) == SQLITE_OK,
    let statement
  else { throw TestFailure.sqlite }
  defer { sqlite3_finalize(statement) }
  let inserted = sentinel.withCString { pointer in
    sqlite3_bind_text(statement, 1, pointer, -1, nil) == SQLITE_OK
      && sqlite3_step(statement) == SQLITE_DONE
  }
  guard inserted else { throw TestFailure.sqlite }
}

private func executeSQLite(_ url: URL, _ sql: String) throws {
  var database: OpaquePointer?
  guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
    let database
  else { throw TestFailure.sqlite }
  defer { sqlite3_close(database) }
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw TestFailure.sqlite }
}

private func appendNULSuffixToSchemaSQL(_ url: URL, object: String) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = [
    // Newer sqlite3 shells (e.g. Homebrew's, first on PATH on CI runners) start in
    // defensive mode, which forbids writing sqlite_schema even with writable_schema.
    "sqlite3", "-batch", "-cmd", ".dbconfig defensive off", url.path,
    "PRAGMA writable_schema=ON; UPDATE sqlite_schema SET sql = sql || CAST(X'0048494444454E5F4452494654' AS TEXT) WHERE type='table' AND name='\(object)';",
  ]
  try process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else { throw TestFailure.sqlite }
}

private func syntheticProfile(for url: URL) throws -> SourceProfile {
  let result = SourceClassifier(profiles: []).classify(url)
  let metadata = try #require(result.metadata)
  return SourceProfile(
    identifier: "synthetic-v19",
    applicationID: metadata.applicationID,
    userVersion: metadata.userVersion,
    schemaSHA256: metadata.schemaSHA256)
}

private func attributes(_ url: URL) throws -> (size: UInt64, modified: Date) {
  let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
  return (UInt64(try #require(values.fileSize)), try #require(values.contentModificationDate))
}

private func makeStoredZIP(
  entries: [(String, Data)],
  at url: URL,
  corruptCRC: Bool = false,
  unixMode: UInt16? = nil
) throws {
  var archive = Data()
  var central = Data()
  for (name, bytes) in entries {
    let nameData = Data(name.utf8)
    let offset = UInt32(archive.count)
    let crc =
      bytes.withUnsafeBytes { buffer in
        csqlite_crc32(buffer.bindMemory(to: UInt8.self).baseAddress, bytes.count)
      } ^ (corruptCRC ? 1 : 0)
    archive.le32(0x0403_4b50)
    archive.le16(20)
    archive.le16(0)
    archive.le16(0)
    archive.le16(0)
    archive.le16(0)
    archive.le32(crc)
    archive.le32(UInt32(bytes.count))
    archive.le32(UInt32(bytes.count))
    archive.le16(UInt16(nameData.count))
    archive.le16(0)
    archive.append(nameData)
    archive.append(bytes)

    central.le32(0x0201_4b50)
    central.le16(unixMode == nil ? 20 : (UInt16(3) << 8) | 20)
    central.le16(20)
    central.le16(0)
    central.le16(0)
    central.le16(0)
    central.le16(0)
    central.le32(crc)
    central.le32(UInt32(bytes.count))
    central.le32(UInt32(bytes.count))
    central.le16(UInt16(nameData.count))
    central.le16(0)
    central.le16(0)
    central.le16(0)
    central.le16(0)
    central.le32(UInt32(unixMode ?? 0) << 16)
    central.le32(offset)
    central.append(nameData)
  }
  let centralOffset = UInt32(archive.count)
  archive.append(central)
  archive.le32(0x0605_4b50)
  archive.le16(0)
  archive.le16(0)
  archive.le16(UInt16(entries.count))
  archive.le16(UInt16(entries.count))
  archive.le32(UInt32(central.count))
  archive.le32(centralOffset)
  archive.le16(0)
  try archive.write(to: url)
}

private func mutateZIP(_ url: URL, _ mutation: (inout Data) throws -> Void) throws {
  var data = try Data(contentsOf: url)
  try mutation(&data)
  try data.write(to: url)
}

private func runZIP(input: URL, output: URL) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
  process.arguments = ["-q", "-Z", "deflate", "-j", output.path, input.path]
  try process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else { throw TestFailure.zip }
}

private func appendTrailingCompressedByte(to url: URL) throws {
  try mutateZIP(url) { data in
    guard let central = data.firstOffset(of: 0x0201_4b50),
      let eocd = data.firstOffset(of: 0x0605_4b50)
    else { throw TestFailure.zip }
    let localCompressed = try data.le32(at: 18)
    let centralCompressed = try data.le32(at: central + 20)
    guard localCompressed == centralCompressed else { throw TestFailure.zip }
    data.insert(0, at: central)
    data.replaceLE32(at: 18, with: localCompressed + 1)
    data.replaceLE32(at: central + 1 + 20, with: centralCompressed + 1)
    data.replaceLE32(at: eocd + 1 + 16, with: UInt32(central + 1))
  }
}

extension Data {
  fileprivate mutating func le16(_ value: UInt16) {
    append(UInt8(value & 0xff))
    append(UInt8(value >> 8))
  }

  fileprivate mutating func le32(_ value: UInt32) {
    append(UInt8(value & 0xff))
    append(UInt8((value >> 8) & 0xff))
    append(UInt8((value >> 16) & 0xff))
    append(UInt8((value >> 24) & 0xff))
  }

  fileprivate func le32(at offset: Int) throws -> UInt32 {
    guard offset >= 0, offset + 4 <= count else { throw TestFailure.zip }
    return UInt32(self[offset]) | (UInt32(self[offset + 1]) << 8)
      | (UInt32(self[offset + 2]) << 16) | (UInt32(self[offset + 3]) << 24)
  }

  fileprivate mutating func replaceLE32(at offset: Int, with value: UInt32) {
    self[offset] = UInt8(value & 0xff)
    self[offset + 1] = UInt8((value >> 8) & 0xff)
    self[offset + 2] = UInt8((value >> 16) & 0xff)
    self[offset + 3] = UInt8((value >> 24) & 0xff)
  }

  fileprivate func firstOffset(of signature: UInt32) -> Int? { offsets(of: signature).first }

  fileprivate func offsets(of signature: UInt32) -> [Int] {
    guard count >= 4 else { return [] }
    return (0...(count - 4)).filter { offset in
      self[offset] == UInt8(signature & 0xff)
        && self[offset + 1] == UInt8((signature >> 8) & 0xff)
        && self[offset + 2] == UInt8((signature >> 16) & 0xff)
        && self[offset + 3] == UInt8((signature >> 24) & 0xff)
    }
  }
}

extension URL {
  fileprivate var fileSize: Int {
    (try? resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
  }
}

private enum TestFailure: Error { case sqlite, zip }
