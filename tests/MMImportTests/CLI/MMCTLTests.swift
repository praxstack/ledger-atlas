import CSQLite
import CryptoKit
import Foundation
import LedgerCore
import Testing

@testable import MMImport

@Suite("mmctl milestone-one surface")
struct MMCTLTests {
  @Test("coverage is explicit, read-only, and content-free")
  func coverageIsReadOnlyAndRedacted() throws {
    try withCLIDirectory { directory in
      let sentinel = "PRIVATE_COVERAGE_SENTINEL"
      let source = directory.appendingPathComponent("\(sentinel).opaque")
      try Data("synthetic-only".utf8).write(to: source)
      let before = try Data(contentsOf: source)

      let result = try runMMCTL(["coverage", source.path, "--json"])

      #expect(result.status == 2)
      #expect(result.stdout.contains("\"receiptVersion\":1"))
      #expect(result.stdout.contains("\"status\":\"unsupported\""))
      #expect(result.stdout.contains("\"sourceSHA256Before\":\""))
      #expect(result.stdout.contains("\"sourceSHA256After\":\""))
      #expect(result.stdout.contains("\"unsupported_container\""))
      #expect(!result.combined.contains(sentinel))
      #expect(!result.combined.contains(source.path))
      #expect(try Data(contentsOf: source) == before)
    }
  }

  @Test("coverage fails closed for an unavailable source without reflecting its path")
  func unavailableCoverageFailsClosed() throws {
    try withCLIDirectory { directory in
      let sentinel = "PRIVATE_MISSING_COVERAGE_SENTINEL"
      let missing = directory.appendingPathComponent("\(sentinel).sqlite")
      let result = try runMMCTL(["coverage", missing.path, "--json"])

      #expect(result.status != 0)
      #expect(result.stdout.contains("\"status\":\"unavailable\""))
      #expect(result.stdout.contains("\"file_not_found\""))
      #expect(result.stdout.contains("\"invalid_coverage_receipt\""))
      #expect(!result.combined.contains(sentinel))
      #expect(!result.combined.contains(missing.path))
    }
  }

  @Test("inspect is a content-free immutable alias")
  func inspectIsImmutable() throws {
    try withCLIDirectory { directory in
      let sentinel = "PRIVATE_CLI_SENTINEL"
      let source = directory.appendingPathComponent("\(sentinel).opaque")
      try Data("synthetic-only".utf8).write(to: source)
      let before = try Data(contentsOf: source)
      let result = try runMMCTL(["inspect", source.path, "--json"])

      #expect(result.status == 2)
      #expect(result.stdout.contains("\"status\":\"unsupported\""))
      #expect(!result.combined.contains(sentinel))
      #expect(!result.combined.contains(source.path))
      #expect(try Data(contentsOf: source) == before)
    }
  }

  @Test("a Money Manager format export is refused and writes nothing")
  func vendorExportIsRefused() throws {
    try withCLIDirectory { directory in
      let sentinel = "PRIVATE_EXPORT_SENTINEL"
      let missing = directory.appendingPathComponent("\(sentinel).mmbak")
      let refused = try runMMCTL(["export", "--format", "mm-v19", "--output", missing.path])

      #expect(refused.status == 3)
      #expect(refused.stderr.contains("vendor_export_unsupported"))
      #expect(!FileManager.default.fileExists(atPath: missing.path))
      #expect(!refused.combined.contains(sentinel))

      // An existing file at the destination is left exactly as it was.
      let existing = directory.appendingPathComponent("existing.mmbak")
      try Data("synthetic-only".utf8).write(to: existing)
      let again = try runMMCTL(["export", "--format", "mm-v19", "--output", existing.path])
      #expect(again.status == 3)
      #expect(try Data(contentsOf: existing) == Data("synthetic-only".utf8))
      #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["existing.mmbak"])

      let unknown = try runMMCTL(["export", "--format", sentinel, "--output", missing.path])
      #expect(unknown.status == 64)
      #expect(!unknown.combined.contains(sentinel))
      #expect(!FileManager.default.fileExists(atPath: missing.path))
    }
  }

  @Test("the library refuses every vendor export format")
  func vendorExportLibraryRefuses() throws {
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("vendor-export-\(UUID().uuidString).mmbak")
    for format in VendorExportFormat.allCases {
      #expect(throws: VendorExportError.vendorExportUnsupported) {
        try VendorExport.export(format, to: destination)
      }
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(VendorExport.notice.contains("Money Manager"))
  }

  @Test("malformed arguments return usage without reflecting input")
  func malformedArgumentsAreRedacted() throws {
    let sentinel = "PRIVATE_BAD_ARGUMENT"
    let result = try runMMCTL([
      "reconcile", "--staging-db", sentinel, "--manifest", sentinel,
    ])

    #expect(result.status == 64)
    #expect(result.stderr.contains("usage: mmctl reconcile"))
    #expect(!result.combined.contains(sentinel))
  }

  @Test("reconcile reports missing mappings deterministically")
  func reconcileMissingMapping() throws {
    try withCLIDirectory { directory in
      let fixture = try makeReconciliationFixture(in: directory)
      let before = try sha256(fixture.stagingURL)
      let result = try runMMCTL([
        "reconcile", "--staging-db", fixture.stagingURL.path,
        "--manifest", fixture.manifestURL.path,
        "--digest", fixture.digest,
        "--decisions", fixture.decisionsURL.path,
        "--json",
      ])

      #expect(result.status == 0)
      #expect(result.stdout.contains("\"blockingCount\":1"))
      #expect(result.stdout.contains("\"missing_mapping\""))
      #expect(!result.combined.contains(fixture.sentinel))
      #expect(!result.combined.contains(fixture.stagingURL.path))
      #expect(try sha256(fixture.stagingURL) == before)
    }
  }

  @Test("expect-zero-loss turns a blocking report into failure")
  func expectZeroLossBlocks() throws {
    try withCLIDirectory { directory in
      let fixture = try makeReconciliationFixture(in: directory)
      let result = try runMMCTL([
        "reconcile", "--staging-db", fixture.stagingURL.path,
        "--manifest", fixture.manifestURL.path,
        "--digest", fixture.digest,
        "--decisions", fixture.decisionsURL.path,
        "--expect-zero-loss", "--json",
      ])

      #expect(result.status != 0)
      #expect(result.stdout.contains("\"blockingCount\":1"))
      #expect(!result.combined.contains(fixture.sentinel))
      #expect(!result.combined.contains(fixture.stagingURL.path))
    }
  }

  @Test("an authenticated empty generic plan is rejected without creating a destination")
  func authenticatedEmptyPlanIsRejected() throws {
    try withCLIDirectory { directory in
      let fixture = try makeReconciliationFixture(in: directory)
      let canonical = directory.appendingPathComponent("\(fixture.sentinel)-canonical.sqlite")
      let request = directory.appendingPathComponent("authenticated-request.json")
      try writeJSONObject(
        [
          "formatVersion": 1,
          "canonicalDatabase": canonical.path,
          "stagingDatabase": fixture.stagingURL.path,
          "manifest": manifestObject(fixture.manifest),
          "stagingDigest": fixture.digest,
          "mappingDecisions": [
            [
              "subjectID": fixture.manifest.stagingID,
              "kind": "artifact",
              "disposition": "preserved",
              "reasonCode": "immutable_source_provenance",
            ] as [String: Any]
          ],
          "events": [],
        ], to: request)
      let before = try sha256(fixture.stagingURL)

      let reconciled = try runMMCTL([
        "reconcile", "--request", request.path, "--expect-zero-loss", "--json",
      ])
      #expect(reconciled.status != 0)
      #expect(reconciled.stdout.contains("invalid_reconciliation_request"))
      #expect(!FileManager.default.fileExists(atPath: canonical.path))
      #expect(!reconciled.combined.contains(fixture.sentinel))
      #expect(!reconciled.combined.contains(fixture.stagingURL.path))
      #expect(try sha256(fixture.stagingURL) == before)

      #expect(!FileManager.default.fileExists(atPath: canonical.path))
      #expect(try sha256(fixture.stagingURL) == before)
    }
  }

  @Test("synthetic v19 inspect, coverage, stage, and reconcile are redacted and retry-identical")
  func syntheticV19InspectCoverageStageReconcileTwice() throws {
    try withCLIDirectory { directory in
      let sentinel = "PRIVATE_V19_PIPELINE_SENTINEL"
      let source = directory.appendingPathComponent("source.sqlite")
      try createSyntheticV19Source(at: source, note: sentinel)
      let before = try Data(contentsOf: source)
      let first = try runSyntheticV19Pipeline(source: source, directory: directory, suffix: "1")
      let second = try runSyntheticV19Pipeline(source: source, directory: directory, suffix: "2")

      for result in first.commands + second.commands {
        #expect(result.status == 0)
        #expect(!result.combined.contains(sentinel))
        #expect(!result.combined.contains(source.path))
        #expect(!result.combined.contains("12.30"))
      }
      #expect(first.inspect.stdout.contains("\"status\":\"supported\""))
      #expect(
        first.inspect.stdout.contains("realbyte-android-v19-synthetic-text-subset-v1"))
      #expect(first.coverage.stdout.contains("\"status\":\"supported\""))
      #expect(first.coverage.stdout.contains("\"sourceSHA256Before\":\""))
      #expect(first.coverage.stdout.contains("\"sourceSHA256After\":\""))
      #expect(first.stage.stdout.contains("\"status\":\"staged\""))
      #expect(first.stage.stdout.contains("money-manager-android-v19-adapter-v1"))
      #expect(
        first.stage.stdout.contains("realbyte-android-v19-synthetic-text-subset-v1"))
      #expect(first.reconcile.stdout.contains("\"blockingCount\":0"))
      #expect(try Data(contentsOf: source) == before)
      #expect(first.inspect.stdout == second.inspect.stdout)
      #expect(first.coverage.stdout == second.coverage.stdout)
      #expect(first.stage.stdout == second.stage.stdout)
      #expect(first.reconcile.stdout == second.reconcile.stdout)
    }
  }

  @Test("bounded observed-v19 request reconciles but cannot write directly")
  func observedV19RequestPath() throws {
    try withCLIDirectory { directory in
      let fixture = try makeObservedV19CLIStage(in: directory)
      let canonical = directory.appendingPathComponent("canonical.sqlite")
      let request = directory.appendingPathComponent("observed-v19-request.json")
      try writeJSONObject(
        [
          "formatVersion": 1,
          "canonicalDatabase": canonical.path,
          "stagingDatabase": fixture.stagingURL.path,
          "manifest": manifestObject(fixture.manifest),
          "stagingDigest": fixture.digest,
          "sourceTimeZone": ["kind": "fixedOffset", "offsetSeconds": 19_800],
        ], to: request)
      let before = try sha256(fixture.stagingURL)

      let reconciled = try runMMCTL([
        "reconcile", "--observed-v19-request", request.path,
        "--expect-zero-loss", "--json",
      ])
      let directWrite = try runMMCTL([
        "commit", "--observed-v19-request", request.path, "--json",
      ])

      #expect(reconciled.status == 0)
      #expect(reconciled.stdout.contains("\"blockingCount\":0"))
      #expect(directWrite.status != 0)
      #expect(!FileManager.default.fileExists(atPath: canonical.path))
      #expect(try sha256(fixture.stagingURL) == before)
      for output in [reconciled.combined, directWrite.combined] {
        #expect(!output.contains(fixture.sentinel))
        #expect(!output.contains(fixture.stagingURL.path))
        #expect(!output.contains(canonical.path))
      }
    }
  }

}

private struct CLIResult {
  let status: Int32
  let stdout: String
  let stderr: String
  var combined: String { stdout + stderr }
}

private struct ReconciliationFixture {
  let stagingURL: URL
  let manifestURL: URL
  let decisionsURL: URL
  let manifest: StagingManifest
  let digest: String
  let sentinel: String
}

private struct SyntheticV19Pipeline {
  let inspect: CLIResult
  let coverage: CLIResult
  let stage: CLIResult
  let reconcile: CLIResult
  var commands: [CLIResult] { [inspect, coverage, stage, reconcile] }
}

private func runSyntheticV19Pipeline(source: URL, directory: URL, suffix: String) throws
  -> SyntheticV19Pipeline
{
  let inspect = try runMMCTL(["inspect", source.path, "--json"])
  let coverage = try runMMCTL(["coverage", source.path, "--json"])
  let staging = directory.appendingPathComponent("stage-\(suffix).sqlite")
  let stage = try runMMCTL([
    "stage", "--input", source.path, "--staging-db", staging.path, "--json",
  ])
  let report = try JSONDecoder().decode(RedactedStagingReport.self, from: Data(stage.stdout.utf8))
  guard let manifest = report.manifest, let digest = report.stagingDigest else {
    throw CLITestError.sqlite
  }
  let canonical = directory.appendingPathComponent("canonical-\(suffix).sqlite")
  let request = directory.appendingPathComponent("observed-v19-request-\(suffix).json")
  try writeJSONObject(
    [
      "formatVersion": 1,
      "canonicalDatabase": canonical.path,
      "stagingDatabase": staging.path,
      "manifest": manifestObject(manifest),
      "stagingDigest": digest,
      "sourceTimeZone": ["kind": "fixedOffset", "offsetSeconds": 0],
    ], to: request)
  let reconcile = try runMMCTL([
    "reconcile", "--observed-v19-request", request.path, "--expect-zero-loss", "--json",
  ])
  return SyntheticV19Pipeline(
    inspect: inspect, coverage: coverage, stage: stage, reconcile: reconcile)
}

private func createSyntheticV19Source(at url: URL, note: String) throws {
  try withDatabase(url) { database in
    let escaped = note.replacingOccurrences(of: "'", with: "''")
    try execute(
      database,
      """
      PRAGMA user_version=19;
      CREATE TABLE ASSETS (uid TEXT); CREATE TABLE ZCATEGORY (uid TEXT);
      CREATE TABLE CURRENCY (uid TEXT, ISO TEXT);
      CREATE TABLE INOUTCOME (uid TEXT, assetUid TEXT, currencyUid TEXT, DO_TYPE TEXT, ctgUid TEXT, ZMONEY TEXT, WDATE TEXT, ZDATE TEXT, NOTE TEXT);
      INSERT INTO ASSETS VALUES ('asset'); INSERT INTO ZCATEGORY VALUES ('category');
      INSERT INTO CURRENCY VALUES ('currency', 'USD');
      INSERT INTO INOUTCOME VALUES ('transaction', 'asset', 'currency', '1', 'category', '12.30', '2025-02-03', '1738547200000', '\(escaped)');
      """)
  }
}

private func makeObservedV19CLIStage(in directory: URL) throws -> ReconciliationFixture {
  let sentinel = "PRIVATE_V19_CLI_SENTINEL"
  let artifact = String(repeating: "b", count: 64)
  let stageID = StableStagingID.stage(
    artifactSHA256: artifact, profileID: MoneyManagerV19Adapter.observedProfileID,
    adapterVersion: MoneyManagerV19Adapter.version)
  func record(_ table: String, _ key: String, _ values: [(String, String)]) throws
    -> StagedRecord
  {
    let fields = try values.enumerated().map { ordinal, pair -> StagedField in
      let locator = SourceLocator(
        table: table, recordKey: key, columnOrdinal: ordinal, columnName: pair.0)
      let fieldID = StableStagingID.field(stagingID: stageID, locator: locator)
      let provenance = FieldProvenance(
        artifactSHA256: artifact, profileID: MoneyManagerV19Adapter.observedProfileID,
        adapterVersion: MoneyManagerV19Adapter.version, locator: locator,
        deterministicID: fieldID)
      return StagedField(
        id: fieldID, ordinal: ordinal, name: pair.0,
        sidecar: try OpaqueSidecar(
          declaredType: "TEXT", storageClass: .text, payload: Data(pair.1.utf8),
          provenance: provenance))
    }
    return StagedRecord(
      id: StableStagingID.record(stagingID: stageID, table: table, recordKey: key),
      recordKey: key, fields: fields,
      opaqueByteCount: fields.reduce(0) { $0 + $1.sidecar.payload.count })
  }
  let records = try [
    record("ASSETS", "asset", [("uid", "synthetic-asset")]),
    record("ZCATEGORY", "category", [("uid", "synthetic-category")]),
    record("CURRENCY", "currency", [("uid", "synthetic-currency"), ("ISO", "USD")]),
    record(
      "INOUTCOME", "event",
      [
        ("uid", "synthetic-transaction"), ("assetUid", "synthetic-asset"),
        ("currencyUid", "synthetic-currency"),
        ("ctgUid", "synthetic-category"), ("DO_TYPE", "1"), ("ZMONEY", "12.30"),
        ("WDATE", "2025-02-03"), ("ZDATE", "1738547200000"), ("NOTE", sentinel),
      ]),
  ]
  let tables = records.map {
    StagedTable(
      id: StableStagingID.table(
        stagingID: stageID, table: $0.fields[0].sidecar.provenance.locator.table),
      name: $0.fields[0].sidecar.provenance.locator.table, records: [$0])
  }
  let manifest = StagingManifest(
    stagingID: stageID, artifactSHA256: artifact,
    profileID: MoneyManagerV19Adapter.observedProfileID,
    adapterVersion: MoneyManagerV19Adapter.version, tableCount: tables.count,
    recordCount: records.count, fieldCount: records.reduce(0) { $0 + $1.fields.count },
    opaqueByteCount: records.reduce(0) { $0 + $1.opaqueByteCount })
  let stage = directory.appendingPathComponent("observed-v19-stage.sqlite")
  let digest = try SQLiteStagingStore().write(
    StagingContents(
      stagingID: stageID, tables: tables, recordCount: manifest.recordCount,
      fieldCount: manifest.fieldCount, opaqueByteCount: manifest.opaqueByteCount),
    manifest: manifest, sourceSizeBytes: 0,
    limitsDescription: StagingLimits.standard.stableDescription, to: stage)
  return ReconciliationFixture(
    stagingURL: stage, manifestURL: directory.appendingPathComponent("unused-manifest"),
    decisionsURL: directory.appendingPathComponent("unused-decisions"), manifest: manifest,
    digest: digest, sentinel: sentinel)
}

private enum CLITestError: Error { case sqlite }

private func runMMCTL(_ arguments: [String]) throws -> CLIResult {
  let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent(".build/debug/mmctl")
  let process = Process()
  let stdout = Pipe()
  let stderr = Pipe()
  process.executableURL = executable
  process.arguments = arguments
  process.standardOutput = stdout
  process.standardError = stderr
  try process.run()
  process.waitUntilExit()
  return CLIResult(
    status: process.terminationStatus,
    stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
    stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}

private func makeReconciliationFixture(in directory: URL) throws -> ReconciliationFixture {
  let sentinel = "PRIVATE_STAGE_SENTINEL"
  let stage = directory.appendingPathComponent("\(sentinel).sqlite")
  let manifestURL = directory.appendingPathComponent("manifest.json")
  let decisionsURL = directory.appendingPathComponent("decisions.json")
  let manifest = StagingManifest(
    stagingID: String(repeating: "a", count: 64),
    artifactSHA256: String(repeating: "f", count: 64),
    profileID: "synthetic-profile", adapterVersion: "synthetic-adapter",
    tableCount: 0, recordCount: 0, fieldCount: 0, opaqueByteCount: 0)
  try createMinimalStage(at: stage, manifest: manifest)
  let digest = try SQLiteStagingStore().contentDigest(at: stage)
  try withDatabase(stage) { database in
    try execute(database, "INSERT INTO staging_meta VALUES('content_digest', '\(digest)')")
  }
  try JSONEncoder().encode(manifest).write(to: manifestURL)
  try writeJSONObject(["formatVersion": 1, "decisions": []], to: decisionsURL)
  return ReconciliationFixture(
    stagingURL: stage, manifestURL: manifestURL, decisionsURL: decisionsURL,
    manifest: manifest, digest: digest, sentinel: sentinel)
}

private func createMinimalStage(at url: URL, manifest: StagingManifest) throws {
  try withDatabase(url) { database in
    let statements = [
      "CREATE TABLE staging_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)",
      "CREATE TABLE staged_artifact(artifact_id TEXT PRIMARY KEY, artifact_sha256 TEXT NOT NULL, profile_id TEXT NOT NULL, adapter_version TEXT NOT NULL, source_size_bytes INTEGER NOT NULL CHECK(source_size_bytes >= 0))",
      "CREATE TABLE staged_table(table_id TEXT PRIMARY KEY, artifact_id TEXT NOT NULL REFERENCES staged_artifact(artifact_id), ordinal INTEGER NOT NULL CHECK(ordinal >= 0), table_name TEXT NOT NULL, record_count INTEGER NOT NULL CHECK(record_count >= 0), UNIQUE(artifact_id, ordinal), UNIQUE(artifact_id, table_name))",
      "CREATE TABLE staged_record(record_id TEXT PRIMARY KEY, table_id TEXT NOT NULL REFERENCES staged_table(table_id), record_key TEXT NOT NULL, field_count INTEGER NOT NULL CHECK(field_count >= 0), opaque_byte_count INTEGER NOT NULL CHECK(opaque_byte_count >= 0), UNIQUE(table_id, record_key))",
      "CREATE TABLE staged_field(field_id TEXT PRIMARY KEY, record_id TEXT NOT NULL REFERENCES staged_record(record_id), ordinal INTEGER NOT NULL CHECK(ordinal >= 0), column_name TEXT NOT NULL, declared_type TEXT, storage_class TEXT NOT NULL CHECK(storage_class IN ('null', 'integer', 'real', 'blob', 'text')), payload BLOB NOT NULL, sidecar_version INTEGER NOT NULL CHECK(sidecar_version = 1), container_member TEXT, UNIQUE(record_id, ordinal))",
      "CREATE TABLE staging_manifest(format_version INTEGER NOT NULL CHECK(format_version = 1), staging_id TEXT PRIMARY KEY REFERENCES staged_artifact(artifact_id), artifact_sha256 TEXT NOT NULL, profile_id TEXT NOT NULL, adapter_version TEXT NOT NULL, table_count INTEGER NOT NULL CHECK(table_count >= 0), record_count INTEGER NOT NULL CHECK(record_count >= 0), field_count INTEGER NOT NULL CHECK(field_count >= 0), opaque_byte_count INTEGER NOT NULL CHECK(opaque_byte_count >= 0))",
      "INSERT INTO staging_meta VALUES('format_version', '1')",
      "INSERT INTO staging_meta VALUES('staging_id', '\(manifest.stagingID)')",
      "INSERT INTO staging_meta VALUES('limits_description', 'synthetic-limits-v1')",
      "INSERT INTO staged_artifact VALUES('\(manifest.stagingID)', '\(manifest.artifactSHA256)', '\(manifest.profileID)', '\(manifest.adapterVersion)', 0)",
      "INSERT INTO staging_manifest VALUES(1, '\(manifest.stagingID)', '\(manifest.artifactSHA256)', '\(manifest.profileID)', '\(manifest.adapterVersion)', 0, 0, 0, 0)",
    ]
    for statement in statements { try execute(database, statement) }
  }
}

private func withDatabase(_ url: URL, _ body: (OpaquePointer) throws -> Void) throws {
  var database: OpaquePointer?
  guard
    sqlite3_open_v2(
      url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
    let database
  else { throw CLITestError.sqlite }
  defer { sqlite3_close(database) }
  try body(database)
}

private func execute(_ database: OpaquePointer, _ sql: String) throws {
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
    throw CLITestError.sqlite
  }
}

private func manifestObject(_ manifest: StagingManifest) -> [String: Any] {
  [
    "formatVersion": manifest.formatVersion, "stagingID": manifest.stagingID,
    "artifactSHA256": manifest.artifactSHA256, "profileID": manifest.profileID,
    "adapterVersion": manifest.adapterVersion, "tableCount": manifest.tableCount,
    "recordCount": manifest.recordCount, "fieldCount": manifest.fieldCount,
    "opaqueByteCount": manifest.opaqueByteCount,
  ]
}

private func writeJSONObject(_ object: Any, to url: URL) throws {
  try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
}

private func sha256(_ url: URL) throws -> String {
  SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

private func withCLIDirectory(_ body: (URL) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "ledger-atlas-cli-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: directory) }
  try body(directory)
}
