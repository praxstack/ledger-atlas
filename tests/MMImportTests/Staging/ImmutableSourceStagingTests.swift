import CSQLite
import Darwin
import Foundation
import LedgerCore
import Testing

@testable import MMImport

@Suite("Immutable SQLite staging")
struct ImmutableSourceStagingTests {
  @Test("all tables, rows, fields, and storage classes are preserved")
  func stagesEverySourceItemLosslessly() throws {
    try withStagingDirectory { directory in
      let source = directory.appendingPathComponent("synthetic.sqlite")
      let destination = directory.appendingPathComponent("staging.sqlite")
      try createAllStorageClassesDatabase(at: source)
      let before = try sourceAttributes(source)
      let sourceBytesBefore = try Data(contentsOf: source)

      let result = try makeStager(for: source).stage(
        StagingRequest(sourceURL: source, stagingDatabaseURL: destination))

      #expect(result.status == .staged)
      #expect(result.stagingDigest.count == 64)
      let redacted = RedactedStagingReport(result)
      #expect(redacted.reportVersion == 2)
      #expect(redacted.manifest == result.manifest)
      #expect(redacted.stagingDigest == result.stagingDigest)
      #expect(redacted.artifactSHA256 == result.manifest.artifactSHA256)
      #expect(redacted.profileID == result.manifest.profileID)
      #expect(redacted.adapterVersion == result.manifest.adapterVersion)
      #expect(result.manifest.tableCount == 2)
      #expect(result.manifest.recordCount == 2)
      #expect(result.manifest.fieldCount == 14)
      #expect(try scalarInt(destination, "SELECT count(*) FROM staged_table") == 2)
      #expect(try scalarInt(destination, "SELECT count(*) FROM staged_record") == 2)
      #expect(try scalarInt(destination, "SELECT count(*) FROM staged_field") == 14)
      #expect(
        try textColumn(
          destination, "SELECT DISTINCT storage_class FROM staged_field ORDER BY storage_class")
          == ["blob", "integer", "null", "real", "text"])
      #expect(
        try blobColumn(
          destination, "SELECT payload FROM staged_field WHERE storage_class='blob'"
        )
        .contains(Data([0, 0xff, 0x7f])))
      #expect(
        try blobColumn(
          destination, "SELECT payload FROM staged_field WHERE storage_class='text'"
        )
        .contains(Data("opaque-unknown".utf8)))
      #expect(
        try blobColumn(
          destination, "SELECT payload FROM staged_field WHERE storage_class='real'"
        )
        .contains(withBigEndianBytes(0x3fb9_9999_9999_999a)))
      #expect(
        try blobColumn(
          destination, "SELECT payload FROM staged_field WHERE column_name='integerish'"
        )
        .contains(withBigEndianBytes(0x8000_0000_0000_0000)))
      #expect(
        try blobColumn(
          destination, "SELECT payload FROM staged_field WHERE declared_type='MYSTERY'"
        )
        .contains(Data("opaque-unknown".utf8)))
      #expect(
        try scalarInt(
          destination,
          "SELECT count(*) FROM staged_field WHERE storage_class='null' AND length(payload)=0")
          == 3)
      #expect(
        try scalarInt(
          destination,
          "SELECT count(*) FROM staged_field WHERE column_name='nullish' AND declared_type IS NULL")
          == 2)

      let after = try sourceAttributes(source)
      #expect(before.size == after.size)
      #expect(before.modified == after.modified)
      #expect(try Data(contentsOf: source) == sourceBytesBefore)
    }
  }

  @Test("same stage reuses exact output with stable IDs and no duplicates")
  func idempotentReuse() throws {
    try withStagingDirectory { directory in
      let source = directory.appendingPathComponent("source.sqlite")
      let destination = directory.appendingPathComponent("stage.sqlite")
      try createAllStorageClassesDatabase(at: source)
      let stager = try makeStager(for: source)

      let first = try stager.stage(
        StagingRequest(sourceURL: source, stagingDatabaseURL: destination))
      let firstIDs = try textColumn(
        destination, "SELECT field_id FROM staged_field ORDER BY field_id")
      let second = try stager.stage(
        StagingRequest(sourceURL: source, stagingDatabaseURL: destination))
      let secondIDs = try textColumn(
        destination, "SELECT field_id FROM staged_field ORDER BY field_id")

      #expect(first.status == .staged)
      #expect(second.status == .reused)
      #expect(first.manifest == second.manifest)
      #expect(firstIDs == secondIDs)
      #expect(try scalarInt(destination, "SELECT count(*) FROM staged_artifact") == 1)
    }
  }

  @Test("NUL-suffixed source schema metadata is rejected before staging")
  func nulSuffixedSchemaMetadataFailsClosed() throws {
    try withStagingDirectory { directory in
      let source = directory.appendingPathComponent("nul-schema.sqlite")
      let destination = directory.appendingPathComponent("stage.sqlite")
      try createAllStorageClassesDatabase(at: source)
      let beforeMutation = SourceClassifier(profiles: []).classify(source)
      let priorMetadata = try #require(beforeMutation.metadata)
      let profile = SourceProfile(
        identifier: "synthetic-profile-v1",
        applicationID: priorMetadata.applicationID,
        userVersion: priorMetadata.userVersion,
        schemaSHA256: priorMetadata.schemaSHA256)
      try appendNULSuffixToSchemaSQL(source, object: "source_rows")
      let current = SourceClassifier(profiles: []).classify(source)
      let fingerprint = try #require(current.fingerprintBefore)
      let forcedSupported = ClassificationResult(
        container: .sqlite,
        fingerprintBefore: fingerprint,
        fingerprintAfter: fingerprint,
        status: .supported,
        profile: profile,
        metadata: current.metadata,
        diagnostics: [])

      #expect(throws: StagingError.sourceSQLiteInvalid) {
        try ImmutableSourceStager(classifier: { _ in forcedSupported }).stage(
          StagingRequest(sourceURL: source, stagingDatabaseURL: destination))
      }
      #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
  }

  @Test("staging reuse rejects a symlink destination")
  func reuseRejectsSymlinkDestination() throws {
    try withStagingDirectory { directory in
      let source = directory.appendingPathComponent("source.sqlite")
      let destination = directory.appendingPathComponent("stage.sqlite")
      let linkedDestination = directory.appendingPathComponent("linked-stage.sqlite")
      try createAllStorageClassesDatabase(at: source)
      let stager = try makeStager(for: source)
      _ = try stager.stage(
        StagingRequest(sourceURL: source, stagingDatabaseURL: destination))
      let before = try Data(contentsOf: destination)
      try FileManager.default.createSymbolicLink(
        at: linkedDestination, withDestinationURL: destination)

      #expect(throws: StagingError.destinationExists) {
        try stager.stage(
          StagingRequest(sourceURL: source, stagingDatabaseURL: linkedDestination))
      }
      let after = try Data(contentsOf: destination)
      #expect(after == before)
    }
  }

  @Test("exclusive staging creation stays bound to its descriptor across a pathname swap")
  func stagingStoreDoesNotFollowReplacementPath() throws {
    try withStagingDirectory { directory in
      let destination = directory.appendingPathComponent("stage.sqlite")
      let parked = directory.appendingPathComponent("parked.sqlite")
      let openedReplacement = directory.appendingPathComponent("opened-replacement.sqlite")
      let replacement = Data()
      let identifier = String(repeating: "a", count: 64)
      let manifest = StagingManifest(
        stagingID: identifier,
        artifactSHA256: String(repeating: "b", count: 64),
        profileID: "synthetic-profile",
        adapterVersion: "synthetic-adapter",
        tableCount: 0,
        recordCount: 0,
        fieldCount: 0,
        opaqueByteCount: 0)
      let contents = StagingContents(
        stagingID: identifier, tables: [], recordCount: 0, fieldCount: 0,
        opaqueByteCount: 0)
      let store = SQLiteStagingStore(
        testingAfterExclusiveCreate: {
          try FileManager.default.moveItem(at: destination, to: parked)
          try replacement.write(to: destination, options: .withoutOverwriting)
        },
        testingAfterDatabaseOpen: {
          try FileManager.default.moveItem(at: destination, to: openedReplacement)
          try FileManager.default.moveItem(at: parked, to: destination)
        })

      #expect(throws: StagingError.stagingWriteFailed) {
        try store.write(
          contents,
          manifest: manifest,
          sourceSizeBytes: 0,
          limitsDescription: StagingLimits.standard.stableDescription,
          to: destination)
      }
      let replacementAfter = try Data(contentsOf: openedReplacement)
      #expect(replacementAfter == replacement)
    }
  }

  @Test("WAL appearance during authenticated reuse blocks the return")
  func reuseRevalidatesSourceAndCompanions() throws {
    try withStagingDirectory { directory in
      let source = directory.appendingPathComponent("source.sqlite")
      let destination = directory.appendingPathComponent("stage.sqlite")
      try createAllStorageClassesDatabase(at: source)
      let profile = try syntheticProfile(source)
      _ = try ImmutableSourceStager(
        classifier: { SourceClassifier(profiles: [profile]).classify($0) }
      ).stage(StagingRequest(sourceURL: source, stagingDatabaseURL: destination))

      let reuse = ImmutableSourceStager(
        classifier: { SourceClassifier(profiles: [profile]).classify($0) },
        beforePublish: { url in
          try Data([1]).write(to: URL(fileURLWithPath: url.path + "-wal"))
        })
      #expect(throws: StagingError.sourceChanged) {
        try reuse.stage(
          StagingRequest(sourceURL: source, stagingDatabaseURL: destination))
      }
      #expect(try siblingTemporaryFiles(of: destination).isEmpty)
    }
  }

  @Test("same-length staged payload tampering prevents reuse")
  func tamperedStageIsNeverReused() throws {
    try withStagingDirectory { directory in
      let source = directory.appendingPathComponent("source.sqlite")
      let destination = directory.appendingPathComponent("stage.sqlite")
      try createAllStorageClassesDatabase(at: source)
      let stager = try makeStager(for: source)
      _ = try stager.stage(
        StagingRequest(sourceURL: source, stagingDatabaseURL: destination))

      try executeWritable(
        destination,
        "UPDATE staged_field SET payload=X'706C61696E2D74657974' "
          + "WHERE storage_class='text' AND length(payload)=10")

      #expect(throws: StagingError.destinationExists) {
        try stager.stage(
          StagingRequest(sourceURL: source, stagingDatabaseURL: destination))
      }
    }
  }

  @Test("tampering plus an attacker-recomputed public digest prevents reuse")
  func recomputedDigestCannotAuthenticateTampering() throws {
    try withStagingDirectory { directory in
      let source = directory.appendingPathComponent("source.sqlite")
      let destination = directory.appendingPathComponent("stage.sqlite")
      try createAllStorageClassesDatabase(at: source)
      let stager = try makeStager(for: source)
      _ = try stager.stage(
        StagingRequest(sourceURL: source, stagingDatabaseURL: destination))

      try executeWritable(
        destination,
        "UPDATE staged_field SET payload=X'706C61696E2D74657974' "
          + "WHERE storage_class='text' AND length(payload)=10")
      let attackerDigest = try SQLiteStagingStore().contentDigest(at: destination)
      try executeWritable(
        destination,
        "UPDATE staging_meta SET value='\(attackerDigest)' WHERE key='content_digest'")

      #expect(throws: StagingError.destinationExists) {
        try stager.stage(
          StagingRequest(sourceURL: source, stagingDatabaseURL: destination))
      }
    }
  }

  @Test("added schema objects prevent reuse even when rows and digest are unchanged")
  func addedViewPreventsReuse() throws {
    try withStagingDirectory { directory in
      let source = directory.appendingPathComponent("source.sqlite")
      let destination = directory.appendingPathComponent("stage.sqlite")
      try createAllStorageClassesDatabase(at: source)
      let stager = try makeStager(for: source)
      _ = try stager.stage(
        StagingRequest(sourceURL: source, stagingDatabaseURL: destination))
      try executeWritable(
        destination, "CREATE VIEW attacker_view AS SELECT payload FROM staged_field")

      #expect(throws: StagingError.destinationExists) {
        try stager.stage(
          StagingRequest(sourceURL: source, stagingDatabaseURL: destination))
      }
    }
  }

  @Test("no source snapshot is created and the staging temporary is owner-only")
  func secureTemporaryFiles() throws {
    try withStagingDirectory { directory in
      let source = directory.appendingPathComponent("source.sqlite")
      let destination = directory.appendingPathComponent("stage.sqlite")
      try createAllStorageClassesDatabase(at: source)
      let profile = try syntheticProfile(source)
      let stager = ImmutableSourceStager(
        classifier: { SourceClassifier(profiles: [profile]).classify($0) },
        beforePublish: { _ in
          let temporary = try siblingTemporaryFiles(of: destination)
            .filter { $0.pathExtension == "tmp" }
          guard temporary.count == 1, temporary[0].pathExtension == "tmp" else {
            throw StagingTestFailure.io
          }
          let modes = try temporary.map(posixMode)
          guard modes == [0o600] else { throw StagingTestFailure.io }
        })

      _ = try stager.stage(
        StagingRequest(sourceURL: source, stagingDatabaseURL: destination))
      #expect(try posixMode(destination) == 0o600)
      #expect(try siblingTemporaryFiles(of: destination).isEmpty)
    }
  }

  @Test("profile and adapter namespaces change deterministic IDs")
  func namespacesIDs() throws {
    try withStagingDirectory { directory in
      let source = directory.appendingPathComponent("source.sqlite")
      try createAllStorageClassesDatabase(at: source)
      let profile = try syntheticProfile(source)
      let alternateProfile = SourceProfile(
        identifier: "synthetic-profile-alternate",
        applicationID: profile.applicationID,
        userVersion: profile.userVersion,
        schemaSHA256: profile.schemaSHA256)
      let firstURL = directory.appendingPathComponent("one.sqlite")
      let secondURL = directory.appendingPathComponent("two.sqlite")
      let thirdURL = directory.appendingPathComponent("three.sqlite")

      let first = try ImmutableSourceStager(
        classifier: { SourceClassifier(profiles: [profile]).classify($0) }
      ).stage(
        StagingRequest(
          sourceURL: source, stagingDatabaseURL: firstURL, adapterVersion: "adapter-v1"))
      let second = try ImmutableSourceStager(
        classifier: { SourceClassifier(profiles: [alternateProfile]).classify($0) }
      ).stage(
        StagingRequest(
          sourceURL: source, stagingDatabaseURL: secondURL, adapterVersion: "adapter-v1"))
      let third = try ImmutableSourceStager(
        classifier: { SourceClassifier(profiles: [profile]).classify($0) }
      ).stage(
        StagingRequest(
          sourceURL: source, stagingDatabaseURL: thirdURL, adapterVersion: "adapter-v2"))

      #expect(first.manifest.stagingID != second.manifest.stagingID)
      #expect(first.manifest.stagingID != third.manifest.stagingID)
      #expect(
        Set(try textColumn(firstURL, "SELECT field_id FROM staged_field"))
          .isDisjoint(
            with: Set(try textColumn(secondURL, "SELECT field_id FROM staged_field"))))
      #expect(
        Set(try textColumn(firstURL, "SELECT field_id FROM staged_field"))
          .isDisjoint(
            with: Set(try textColumn(thirdURL, "SELECT field_id FROM staged_field"))))
    }
  }

  @Test("per-value, per-record, and total bounds publish nothing")
  func boundsFailClosed() throws {
    try withStagingDirectory { directory in
      let source = directory.appendingPathComponent("source.sqlite")
      try createAllStorageClassesDatabase(at: source)
      let cases: [(String, StagingLimits, StagingError)] = [
        ("value", try StagingLimits(maximumValueBytes: 2), .valueLimitExceeded),
        (
          "record",
          try StagingLimits(maximumValueBytes: 16, maximumRecordBytes: 16),
          .recordLimitExceeded
        ),
        (
          "total",
          try StagingLimits(
            maximumValueBytes: 16, maximumRecordBytes: 60, maximumTotalBytes: 60),
          .totalLimitExceeded
        ),
      ]
      for (name, limits, expected) in cases {
        let destination = directory.appendingPathComponent("\(name).sqlite")
        #expect(throws: expected) {
          try makeStager(for: source).stage(
            StagingRequest(
              sourceURL: source, stagingDatabaseURL: destination, limits: limits))
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
      }
    }
  }

  @Test("global field, metadata, and canonical-memory bounds include NULL fields")
  func aggregateBoundsFailClosed() throws {
    try withStagingDirectory { directory in
      let source = directory.appendingPathComponent("nulls.sqlite")
      try createNullFieldsDatabase(at: source)
      let cases: [(String, StagingLimits, StagingError)] = [
        ("fields", try StagingLimits(maximumFields: 3), .fieldLimitExceeded),
        ("metadata", try StagingLimits(maximumMetadataBytes: 4), .metadataLimitExceeded),
        ("canonical", try StagingLimits(maximumCanonicalBytes: 32), .canonicalLimitExceeded),
      ]
      for (name, limits, expected) in cases {
        let destination = directory.appendingPathComponent("\(name).sqlite")
        #expect(throws: expected) {
          try makeStager(for: source).stage(
            StagingRequest(
              sourceURL: source, stagingDatabaseURL: destination, limits: limits))
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
      }
    }
  }

  @Test("unsupported classification and ZIP selection gaps block before output")
  func classificationMustBeDirectSupportedSQLite() throws {
    try withStagingDirectory { directory in
      let source = directory.appendingPathComponent("source.sqlite")
      try createAllStorageClassesDatabase(at: source)
      let destination = directory.appendingPathComponent("stage.sqlite")
      let unsupported = SourceClassifier(profiles: []).classify(source)
      #expect(throws: StagingError.unsupportedClassification) {
        try ImmutableSourceStager(classifier: { _ in unsupported }).stage(
          StagingRequest(sourceURL: source, stagingDatabaseURL: destination))
      }
      #expect(!FileManager.default.fileExists(atPath: destination.path))

      let profile = try syntheticProfile(source)
      let direct = SourceClassifier(profiles: [profile]).classify(source)
      let zipResult = ClassificationResult(
        container: .zip,
        fingerprintBefore: direct.fingerprintBefore,
        fingerprintAfter: direct.fingerprintAfter,
        status: .supported,
        profile: direct.profile,
        metadata: direct.metadata,
        diagnostics: [])
      #expect(throws: StagingError.selectedZIPMemberUnavailable) {
        try ImmutableSourceStager(classifier: { _ in zipResult }).stage(
          StagingRequest(sourceURL: source, stagingDatabaseURL: destination))
      }
      #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
  }

  @Test("source mutation at the pre-publish seam blocks atomically")
  func sourceChangeBlocksPublish() throws {
    try withStagingDirectory { directory in
      let source = directory.appendingPathComponent("source.sqlite")
      let destination = directory.appendingPathComponent("stage.sqlite")
      try createAllStorageClassesDatabase(at: source)
      let profile = try syntheticProfile(source)
      let stager = ImmutableSourceStager(
        classifier: { SourceClassifier(profiles: [profile]).classify($0) },
        beforePublish: { url in
          let handle = try FileHandle(forWritingTo: url)
          try handle.seekToEnd()
          try handle.write(contentsOf: Data([0]))
          try handle.close()
        })

      #expect(throws: StagingError.sourceChanged) {
        try stager.stage(
          StagingRequest(sourceURL: source, stagingDatabaseURL: destination))
      }
      #expect(!FileManager.default.fileExists(atPath: destination.path))
      #expect(try siblingTemporaryFiles(of: destination).isEmpty)
    }
  }

  @Test("pathname swap and restore invalidates the pinned source")
  func pathnameSwapAndRestoreFailsClosed() throws {
    try withStagingDirectory { directory in
      let source = directory.appendingPathComponent("source.sqlite")
      let alternate = directory.appendingPathComponent("alternate.sqlite")
      let parked = directory.appendingPathComponent("parked.sqlite")
      let destination = directory.appendingPathComponent("stage.sqlite")
      try createAllStorageClassesDatabase(at: source)
      try FileManager.default.copyItem(at: source, to: alternate)
      try executeWritable(
        alternate,
        "UPDATE source_rows SET textish='other-text' WHERE textish='plain-text'")
      #expect(try sourceAttributes(source).size == sourceAttributes(alternate).size)
      let profile = try syntheticProfile(source)
      let stager = ImmutableSourceStager(
        classifier: { SourceClassifier(profiles: [profile]).classify($0) },
        beforePublish: { url in
          try FileManager.default.moveItem(at: url, to: parked)
          try FileManager.default.moveItem(at: alternate, to: url)
          try FileManager.default.moveItem(at: url, to: alternate)
          try FileManager.default.moveItem(at: parked, to: url)
        })

      #expect(throws: StagingError.sourceChanged) {
        try stager.stage(
          StagingRequest(sourceURL: source, stagingDatabaseURL: destination))
      }
      #expect(!FileManager.default.fileExists(atPath: destination.path))
      #expect(try siblingTemporaryFiles(of: destination).isEmpty)
    }
  }

  @Test("temporary swap after authentication never publishes the replacement")
  func temporarySwapAfterAuthenticationFailsClosed() throws {
    try withStagingDirectory { directory in
      let source = directory.appendingPathComponent("source.sqlite")
      let destination = directory.appendingPathComponent("stage.sqlite")
      let parked = directory.appendingPathComponent("authenticated.sqlite")
      let victim = directory.appendingPathComponent("victim.sqlite")
      try createAllStorageClassesDatabase(at: source)
      try createAllStorageClassesDatabase(at: victim)
      let profile = try syntheticProfile(source)
      let stager = ImmutableSourceStager(
        classifier: { SourceClassifier(profiles: [profile]).classify($0) },
        afterTemporaryAuthentication: { temporary in
          try FileManager.default.moveItem(at: temporary, to: parked)
          try FileManager.default.moveItem(at: victim, to: temporary)
        })

      #expect(throws: StagingError.stagingWriteFailed) {
        try stager.stage(
          StagingRequest(sourceURL: source, stagingDatabaseURL: destination))
      }
      #expect(!FileManager.default.fileExists(atPath: destination.path))
      #expect(FileManager.default.fileExists(atPath: source.path))
      #expect(FileManager.default.fileExists(atPath: parked.path))
    }
  }

  @Test("reuse rejects a destination swapped after authentication")
  func reuseSwapAfterAuthenticationFailsClosed() throws {
    try withStagingDirectory { directory in
      let source = directory.appendingPathComponent("source.sqlite")
      let destination = directory.appendingPathComponent("stage.sqlite")
      let parked = directory.appendingPathComponent("parked.sqlite")
      let replacement = directory.appendingPathComponent("replacement.sqlite")
      try createAllStorageClassesDatabase(at: source)
      let profile = try syntheticProfile(source)
      let initial = ImmutableSourceStager(
        classifier: { SourceClassifier(profiles: [profile]).classify($0) })
      _ = try initial.stage(
        StagingRequest(sourceURL: source, stagingDatabaseURL: destination))
      try FileManager.default.copyItem(at: destination, to: replacement)

      let reuse = ImmutableSourceStager(
        classifier: { SourceClassifier(profiles: [profile]).classify($0) },
        beforePublish: { _ in
          try FileManager.default.moveItem(at: destination, to: parked)
          try FileManager.default.createSymbolicLink(
            at: destination, withDestinationURL: replacement)
        })
      #expect(throws: StagingError.destinationExists) {
        try reuse.stage(
          StagingRequest(sourceURL: source, stagingDatabaseURL: destination))
      }
      #expect(FileManager.default.fileExists(atPath: source.path))
      #expect(try isSymbolicLink(destination))
      #expect(FileManager.default.fileExists(atPath: parked.path))
    }
  }

  @Test("redacted reports and CLI failures expose no values or paths")
  func diagnosticsAreContentFree() throws {
    try withStagingDirectory { directory in
      let sentinel = "PRIVATE_SENTINEL_MUST_NOT_APPEAR"
      let source = directory.appendingPathComponent("\(sentinel).opaque")
      let destination = directory.appendingPathComponent("\(sentinel)-stage.sqlite")
      try Data(sentinel.utf8).write(to: source)
      let report = RedactedStagingReport(error: .unsupportedClassification)
      let encoded = String(decoding: try report.jsonData(), as: UTF8.self)
      #expect(!encoded.contains(sentinel))
      #expect(!encoded.contains(source.path))

      let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/debug/mmctl")
      let process = Process()
      let stdout = Pipe()
      let stderr = Pipe()
      process.executableURL = executable
      process.arguments = [
        "stage", "--input", source.path, "--staging-db", destination.path, "--json",
      ]
      process.standardOutput = stdout
      process.standardError = stderr
      try process.run()
      process.waitUntilExit()
      let output = String(
        decoding: stdout.fileHandleForReading.readDataToEndOfFile()
          + stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      #expect(process.terminationStatus != 0)
      #expect(!output.contains(sentinel))
      #expect(!output.contains(source.path))
      #expect(output.contains("unsupported_classification"))
      #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
  }

  @Test("sidecar Codable validation preserves typed representations")
  func sidecarValidation() throws {
    let locator = SourceLocator(
      table: "synthetic", recordKey: "record", columnOrdinal: 0, columnName: "value")
    let provenance = FieldProvenance(
      artifactSHA256: String(repeating: "a", count: 64),
      profileID: "profile",
      adapterVersion: "adapter",
      locator: locator,
      deterministicID: "field")
    let sidecar = try OpaqueSidecar(
      declaredType: "REAL",
      storageClass: .real,
      payload: withBigEndianBytes(0x3ff8_0000_0000_0000),
      provenance: provenance,
      maximumBytes: 8)
    let roundTripped = try JSONDecoder().decode(
      OpaqueSidecar.self, from: JSONEncoder().encode(sidecar))
    #expect(roundTripped == sidecar)
    #expect(throws: OpaqueSidecarError.invalidPayload) {
      try OpaqueSidecar(
        declaredType: nil,
        storageClass: .null,
        payload: Data([1]),
        provenance: provenance)
    }
  }
}

private func makeStager(for source: URL) throws -> ImmutableSourceStager {
  let profile = try syntheticProfile(source)
  return ImmutableSourceStager(
    classifier: { SourceClassifier(profiles: [profile]).classify($0) })
}

private func syntheticProfile(_ source: URL) throws -> SourceProfile {
  let result = SourceClassifier(profiles: []).classify(source)
  guard let metadata = result.metadata else { throw StagingTestFailure.classification }
  return SourceProfile(
    identifier: "synthetic-profile-v1",
    applicationID: metadata.applicationID,
    userVersion: metadata.userVersion,
    schemaSHA256: metadata.schemaSHA256)
}

private func createAllStorageClassesDatabase(at url: URL) throws {
  var database: OpaquePointer?
  guard
    sqlite3_open_v2(
      url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
    let database
  else { throw StagingTestFailure.sqlite }
  defer { sqlite3_close(database) }
  let statements = [
    "PRAGMA user_version=19",
    "CREATE TABLE empty_table(unmodeled TEXT)",
    "CREATE TABLE source_rows(id INTEGER PRIMARY KEY, nullish, integerish INTEGER, realish REAL, blobish BLOB, textish TEXT, unknown_extension MYSTERY)",
    "INSERT INTO source_rows VALUES(1, NULL, -9223372036854775808, 0.1, X'00FF7F', 'plain-text', 'opaque-unknown')",
    "INSERT INTO source_rows VALUES(2, NULL, 42, 1.5, X'', 'second', NULL)",
  ]
  for sql in statements {
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
      throw StagingTestFailure.sqlite
    }
  }
}

private func createNullFieldsDatabase(at url: URL) throws {
  var database: OpaquePointer?
  guard
    sqlite3_open_v2(
      url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
    let database
  else { throw StagingTestFailure.sqlite }
  defer { sqlite3_close(database) }
  for sql in [
    "PRAGMA user_version=19",
    "CREATE TABLE null_rows(first_column, second_column)",
    "INSERT INTO null_rows VALUES(NULL, NULL)",
    "INSERT INTO null_rows VALUES(NULL, NULL)",
  ] {
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
      throw StagingTestFailure.sqlite
    }
  }
}

private func withStagingDirectory(_ body: (URL) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "ledger-atlas-staging-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: directory) }
  try body(directory)
}

private func sourceAttributes(_ url: URL) throws -> (size: Int, modified: Date) {
  let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
  guard let size = values.fileSize, let modified = values.contentModificationDate else {
    throw StagingTestFailure.io
  }
  return (size, modified)
}

private func posixMode(_ url: URL) throws -> Int {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  guard let permissions = attributes[.posixPermissions] as? NSNumber else {
    throw StagingTestFailure.io
  }
  return permissions.intValue & 0o777
}

private func isSymbolicLink(_ url: URL) throws -> Bool {
  var status = stat()
  guard lstat(url.path, &status) == 0 else { throw StagingTestFailure.io }
  return (status.st_mode & S_IFMT) == S_IFLNK
}

private func scalarInt(_ url: URL, _ sql: String) throws -> Int64 {
  try withReadonlyDatabase(url) { database in
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement
    else { throw StagingTestFailure.sqlite }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw StagingTestFailure.sqlite }
    return sqlite3_column_int64(statement, 0)
  }
}

private func textColumn(_ url: URL, _ sql: String) throws -> [String] {
  try withReadonlyDatabase(url) { database in
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement
    else { throw StagingTestFailure.sqlite }
    defer { sqlite3_finalize(statement) }
    var values: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let text = sqlite3_column_text(statement, 0) else {
        throw StagingTestFailure.sqlite
      }
      values.append(String(cString: text))
    }
    return values
  }
}

private func blobColumn(_ url: URL, _ sql: String) throws -> [Data] {
  try withReadonlyDatabase(url) { database in
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement
    else { throw StagingTestFailure.sqlite }
    defer { sqlite3_finalize(statement) }
    var values: [Data] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let count = Int(sqlite3_column_bytes(statement, 0))
      if count == 0 {
        values.append(Data())
      } else if let bytes = sqlite3_column_blob(statement, 0) {
        values.append(Data(bytes: bytes, count: count))
      } else {
        throw StagingTestFailure.sqlite
      }
    }
    return values
  }
}

private func withReadonlyDatabase<T>(
  _ url: URL,
  _ body: (OpaquePointer) throws -> T
) throws -> T {
  var database: OpaquePointer?
  guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
    let database
  else { throw StagingTestFailure.sqlite }
  defer { sqlite3_close(database) }
  return try body(database)
}

private func executeWritable(_ url: URL, _ sql: String) throws {
  var database: OpaquePointer?
  guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
    let database
  else { throw StagingTestFailure.sqlite }
  defer { sqlite3_close(database) }
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
    throw StagingTestFailure.sqlite
  }
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
  guard process.terminationStatus == 0 else { throw StagingTestFailure.sqlite }
}

private func siblingTemporaryFiles(of destination: URL) throws -> [URL] {
  try FileManager.default.contentsOfDirectory(
    at: destination.deletingLastPathComponent(),
    includingPropertiesForKeys: nil
  ).filter { $0.lastPathComponent.hasPrefix(".\(destination.lastPathComponent).") }
}

private func withBigEndianBytes(_ value: UInt64) -> Data {
  var bigEndian = value.bigEndian
  return withUnsafeBytes(of: &bigEndian) { Data($0) }
}

private enum StagingTestFailure: Error { case classification, io, sqlite }
