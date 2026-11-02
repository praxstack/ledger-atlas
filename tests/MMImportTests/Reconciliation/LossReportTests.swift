import CSQLite
import Darwin
import Foundation
import Testing

@testable import MMImport

@Suite("Lossless staged-source reconciliation")
struct LossReportTests {
  @Test("evidence is an opaque target-bound value, not a public enum case")
  func evidenceAPIShapeIsOpaque() throws {
    let stageDigest = hexID("9")
    let proof = TargetBoundReconciliationProof(
      stageDigest: stageDigest, subjectID: hexID("a"), kind: .artifact,
      disposition: .mapped, targetComponents: ["canonical-target", hexID("1")])
    let evidence = try #require(ReconciliationEvidence.canonicalMapping(proof))
    let wrongDisposition = TargetBoundReconciliationProof(
      stageDigest: stageDigest, subjectID: hexID("a"), kind: .artifact,
      disposition: .excluded, targetComponents: ["approved-exclusion", hexID("2")])

    #expect(Mirror(reflecting: evidence).displayStyle == .struct)
    #expect(evidence.targetProofToken != "caller-controlled")
    #expect(ReconciliationEvidence.canonicalMapping(wrongDisposition) == nil)
    #expect(
      evidence.bindingToken(
        expectedStageDigest: stageDigest, expectedSubjectID: hexID("a"),
        expectedKind: .artifact, expectedDisposition: .mapped) != nil)
    #expect(
      evidence.bindingToken(
        expectedStageDigest: stageDigest, expectedSubjectID: hexID("b"),
        expectedKind: .artifact, expectedDisposition: .mapped) == nil)
  }

  @Test("a public client cannot compile a caller-selected proof token")
  func publicClientCannotConstructEvidence() throws {
    #expect(
      try publicClientTypechecks("let _: ReconciliationEvidence.Type = ReconciliationEvidence.self")
    )
    #expect(
      try !publicClientTypechecks(
        "let _ = ReconciliationEvidence.canonicalMapping(stageDigest: String(repeating: \"a\", count: 64), subjectID: String(repeating: \"b\", count: 64), kind: .record, proofToken: String(repeating: \"c\", count: 64))"
      ))
  }

  @Test("every staged level is explicit, sorted, deterministic, and idempotent")
  func completeInventoryIsDeterministic() throws {
    try withReconciliationDirectory { directory in
      let stage = directory.appendingPathComponent("stage.sqlite")
      try createSyntheticStage(at: stage)
      let decisions = [
        ReconciliationDecision(
          subjectID: hexID("a"), kind: .artifact, disposition: .preserved,
          reasonCode: "immutable_source_provenance",
          evidence: try evidence(
            for: .preserved, subjectID: hexID("a"), kind: .artifact, stage: stage)),
        ReconciliationDecision(
          subjectID: hexID("b"), kind: .table, disposition: .mapped,
          reasonCode: "known_table_adapter",
          evidence: try evidence(
            for: .mapped, subjectID: hexID("b"), kind: .table, stage: stage)),
        ReconciliationDecision(
          subjectID: hexID("c"), kind: .record, disposition: .mapped,
          reasonCode: "known_record_adapter",
          evidence: try evidence(
            for: .mapped, subjectID: hexID("c"), kind: .record, stage: stage)),
        ReconciliationDecision(
          subjectID: hexID("d"), kind: .field, disposition: .preserved,
          reasonCode: "tombstone_preserved",
          evidence: try evidence(
            for: .preserved, subjectID: hexID("d"), kind: .field, stage: stage)),
        ReconciliationDecision(
          subjectID: hexID("e"), kind: .table, disposition: .excluded,
          reasonCode: "adapter_metadata_table",
          evidence: try evidence(
            for: .excluded, subjectID: hexID("e"), kind: .table, stage: stage)),
      ]

      let first = try reconcileStage(stage, decisions: decisions)
      let second = try reconcileStage(stage, decisions: decisions)
      let changedEvidence =
        [
          ReconciliationDecision(
            subjectID: hexID("a"), kind: .artifact, disposition: .preserved,
            reasonCode: "immutable_source_provenance",
            evidence: targetEvidence(
              stageDigest: try SQLiteStagingStore().contentDigest(at: stage),
              subjectID: hexID("a"), kind: .artifact, disposition: .preserved,
              targetComponents: ["changed-preservation", hexID("4")]))
        ] + Array(decisions.dropFirst())
      let changed = try reconcileStage(stage, decisions: changedEvidence)

      #expect(first == second)
      #expect(first.reportHash == second.reportHash)
      #expect(first.entries.count == 5)
      #expect(first.entries.map(\.kind) == [.artifact, .table, .table, .record, .field])
      #expect(first.mappedCount == 2)
      #expect(first.preservedCount == 2)
      #expect(first.excludedCount == 1)
      #expect(first.entries.contains { $0.reasonCode == .tombstonePreserved })
      #expect(first.entries.allSatisfy { $0.evidenceToken?.count == 64 })
      #expect(changed.blockingCount == 0)
      #expect(changed.reportHash != first.reportHash)
      #expect(changed.entries.first?.evidenceToken != first.entries.first?.evidenceToken)
      #expect(first.blockingCount == 0)
      #expect(try first.requireZeroLoss() == first)
    }
  }

  @Test("missing mappings block instead of disappearing")
  func missingMappingBlocks() throws {
    try withReconciliationDirectory { directory in
      let stage = directory.appendingPathComponent("stage.sqlite")
      try createSyntheticStage(at: stage)

      let report = try reconcileStage(
        stage,
        decisions: [
          ReconciliationDecision(
            subjectID: hexID("a"), kind: .artifact, disposition: .preserved,
            reasonCode: "immutable_source_provenance",
            evidence: try evidence(
              for: .preserved, subjectID: hexID("a"), kind: .artifact, stage: stage))
        ])

      #expect(report.entries.count == 5)
      #expect(report.blockingCount == 4)
      #expect(report.entries.filter { $0.reasonCode == .missingMapping }.count == 4)
      #expect(throws: ReconciliationError.expectZeroLossFailed) {
        try report.requireZeroLoss()
      }
    }
  }

  @Test("decision subject identifiers are bounded before grouping")
  func invalidDecisionSubjectBlocks() throws {
    try withReconciliationDirectory { directory in
      let stage = directory.appendingPathComponent("invalid-decision.sqlite")
      try createSyntheticStage(at: stage)

      #expect(throws: ReconciliationError.invalidDecision) {
        try reconcileStage(
          stage,
          decisions: [
            ReconciliationDecision(
              subjectID: String(repeating: "a", count: 1_000_001), kind: .field,
              disposition: .blocked, reasonCode: .unknownSubject)
          ])
      }
    }
  }

  @Test("duplicate decisions are blocking")
  func inconsistentGraphBlocks() throws {
    try withReconciliationDirectory { directory in
      let stage = directory.appendingPathComponent("inconsistent.sqlite")
      try createSyntheticStage(at: stage)

      let report = try reconcileStage(
        stage,
        decisions: [
          ReconciliationDecision(
            subjectID: hexID("a"), kind: .artifact, disposition: .preserved,
            reasonCode: "immutable_source_provenance"),
          ReconciliationDecision(
            subjectID: hexID("a"), kind: .artifact, disposition: .preserved,
            reasonCode: "immutable_source_provenance"),
        ])

      #expect(report.entries.count == 5)
      #expect(report.entries.contains { $0.reasonCode == .duplicateDecision })
      #expect(report.blockingCount == report.entries.count)
    }
  }

  @Test("foreign-key orphans are rejected before certification")
  func orphanStagingGraphIsRejected() throws {
    try withReconciliationDirectory { directory in
      let stage = directory.appendingPathComponent("orphan.sqlite")
      try createSyntheticStage(at: stage, orphanRecord: true)

      #expect(throws: ReconciliationError.invalidStagingDatabase) {
        try reconcileStage(stage, decisions: [])
      }
    }
  }

  @Test("mapped, preserved, and excluded decisions require matching evidence")
  func missingOrMismatchedEvidenceBlocks() throws {
    try withReconciliationDirectory { directory in
      let stage = directory.appendingPathComponent("missing-evidence.sqlite")
      try createSyntheticStage(at: stage)
      let report = try reconcileStage(
        stage,
        decisions: [
          ReconciliationDecision(
            subjectID: hexID("a"), kind: .artifact, disposition: .preserved,
            reasonCode: "immutable_source_provenance"),
          ReconciliationDecision(
            subjectID: hexID("b"), kind: .table, disposition: .mapped,
            reasonCode: "known_table_adapter",
            evidence: targetEvidence(
              stageDigest: try SQLiteStagingStore().contentDigest(at: stage),
              subjectID: hexID("b"), kind: .table, disposition: .excluded,
              targetComponents: ["approved-exclusion", hexID("3")])),
          ReconciliationDecision(
            subjectID: hexID("c"), kind: .record, disposition: .mapped,
            reasonCode: "known_record_adapter",
            evidence: targetEvidence(
              stageDigest: try SQLiteStagingStore().contentDigest(at: stage),
              subjectID: hexID("9"), kind: .record, disposition: .mapped,
              targetComponents: ["canonical-target", hexID("1")])),
          ReconciliationDecision(
            subjectID: hexID("d"), kind: .field, disposition: .preserved,
            reasonCode: "tombstone_preserved",
            evidence: targetEvidence(
              stageDigest: hexID("9"), subjectID: hexID("d"), kind: .field,
              disposition: .preserved,
              targetComponents: ["preserved-sidecar", hexID("2")])),
        ])

      #expect(report.entries.contains { $0.reasonCode == .missingDecisionEvidence })
      #expect(report.entries.filter { $0.reasonCode == .invalidDecisionEvidence }.count == 3)
      #expect(throws: ReconciliationError.expectZeroLossFailed) {
        try report.requireZeroLoss()
      }
    }
  }

  @Test("syntactically safe but unregistered reason codes never enter reports")
  func unregisteredReasonCodesBlock() throws {
    try withReconciliationDirectory { directory in
      let stage = directory.appendingPathComponent("unregistered-reasons.sqlite")
      try createSyntheticStage(at: stage)
      let report = try reconcileStage(
        stage,
        decisions: [
          ReconciliationDecision(
            subjectID: hexID("a"), kind: .artifact, disposition: .preserved,
            reasonCode: "plausible_but_unregistered",
            evidence: try evidence(
              for: .preserved, subjectID: hexID("a"), kind: .artifact, stage: stage)),
          ReconciliationDecision(
            subjectID: hexID("b"), kind: .table, disposition: .mapped,
            reasonCode: "123456",
            evidence: try evidence(
              for: .mapped, subjectID: hexID("b"), kind: .table, stage: stage)),
          ReconciliationDecision(
            subjectID: hexID("c"), kind: .record, disposition: .mapped,
            reasonCode: hexID("f"),
            evidence: try evidence(
              for: .mapped, subjectID: hexID("c"), kind: .record, stage: stage)),
          ReconciliationDecision(
            subjectID: hexID("d"), kind: .field, disposition: .preserved,
            reasonCode: "tombstone_preserved",
            evidence: try evidence(
              for: .preserved, subjectID: hexID("d"), kind: .field, stage: stage)),
          ReconciliationDecision(
            subjectID: hexID("e"), kind: .table, disposition: .excluded,
            reasonCode: "adapter_metadata_table",
            evidence: try evidence(
              for: .excluded, subjectID: hexID("e"), kind: .table, stage: stage)),
        ])

      #expect(report.entries.filter { $0.reasonCode == .invalidReasonCode }.count == 3)
      #expect(throws: ReconciliationError.expectZeroLossFailed) {
        try report.requireZeroLoss()
      }
    }
  }

  @Test("hostile identifiers, names, values, and paths never enter report surfaces")
  func reportIsContentFree() throws {
    try withReconciliationDirectory { directory in
      let sentinel = "PRIVATE_SENTINEL_MUST_NOT_APPEAR"
      let stage = directory.appendingPathComponent("\(sentinel).sqlite")
      try createSyntheticStage(at: stage, hostileText: sentinel)
      let before = try Data(contentsOf: stage)

      let report = try StagingReconciler().reconcile(
        stagingDatabaseURL: stage,
        expectedManifest: syntheticManifest(opaqueByteCount: sentinel.utf8.count),
        expectedContentDigest: try SQLiteStagingStore().contentDigest(at: stage),
        decisions: [
          ReconciliationDecision(
            subjectID: hexID("d"), kind: .field, disposition: .mapped,
            reasonCode: sentinel,
            evidence: try evidence(
              for: .mapped, subjectID: hexID("d"), kind: .field, stage: stage))
        ])
      let after = try Data(contentsOf: stage)
      let json = String(decoding: try report.jsonData(), as: UTF8.self)
      let human = report.humanDescription

      #expect(!json.contains(sentinel))
      #expect(!human.contains(sentinel))
      #expect(!json.contains(stage.path))
      #expect(!human.contains(stage.path))
      #expect(before == after)
      #expect(report.entries.count == 5)
      #expect(report.entries.allSatisfy { $0.subjectToken.count == 64 })
      #expect(report.entries.contains { $0.reasonCode == .invalidReasonCode })
    }
  }

  @Test("unknown staging schemas block with a content-free error")
  func unknownSchemaBlocks() throws {
    try withReconciliationDirectory { directory in
      let sentinel = "PRIVATE_SCHEMA_SENTINEL_MUST_NOT_APPEAR"
      let stage = directory.appendingPathComponent("\(sentinel).sqlite")
      try withWritableDatabase(stage) { database in
        try execute(database, "CREATE TABLE hostile_name(value TEXT)")
        try execute(database, "INSERT INTO hostile_name VALUES('\(sentinel)')")
      }

      do {
        _ = try StagingReconciler().reconcile(
          stagingDatabaseURL: stage, expectedManifest: syntheticManifest(),
          expectedContentDigest: hexID("9"), decisions: [])
        Issue.record("unknown staging schema unexpectedly reconciled")
      } catch let error as ReconciliationError {
        #expect(error == .invalidStagingDatabase)
        #expect(!error.rawValue.contains(sentinel))
        #expect(!error.rawValue.contains(stage.path))
      }
    }
  }

  @Test("self-consistent weakened or extended staging schemas are rejected")
  func alteredSchemaBlocks() throws {
    try withReconciliationDirectory { directory in
      let weakened = directory.appendingPathComponent("weakened.sqlite")
      try createSyntheticStage(at: weakened)
      try withWritableDatabase(weakened) { database in
        try execute(database, "DROP TABLE staged_field")
        try execute(
          database,
          "CREATE TABLE staged_field(field_id TEXT, record_id TEXT, ordinal INTEGER, column_name TEXT, declared_type TEXT, storage_class TEXT, payload BLOB, sidecar_version INTEGER, container_member TEXT)"
        )
        try execute(
          database,
          "INSERT INTO staged_field VALUES('\(hexID("d"))', '\(hexID("c"))', 0, 'synthetic-safe-value', 'TEXT', 'text', CAST('synthetic-safe-value' AS BLOB), 1, NULL)"
        )
      }
      try rewriteDigest(at: weakened)

      #expect(throws: ReconciliationError.invalidStagingDatabase) {
        try reconcileStage(weakened, decisions: [])
      }

      let extended = directory.appendingPathComponent("extended.sqlite")
      try createSyntheticStage(at: extended)
      try withWritableDatabase(extended) { database in
        try execute(database, "CREATE TABLE unexpected_extension(value TEXT)")
      }
      try rewriteDigest(at: extended)

      #expect(throws: ReconciliationError.invalidStagingDatabase) {
        try reconcileStage(extended, decisions: [])
      }

      let literalDrift = directory.appendingPathComponent("literal-drift.sqlite")
      try createSyntheticStage(at: literalDrift, literalWhitespaceDrift: true)

      #expect(throws: ReconciliationError.invalidStagingDatabase) {
        try reconcileStage(literalDrift, decisions: [])
      }
    }
  }

  @Test("an attacker-recomputed digest cannot replace the external binding")
  func externalDigestBindingBlocksRecomputedDigest() throws {
    try withReconciliationDirectory { directory in
      let stage = directory.appendingPathComponent("digest-recomputed.sqlite")
      try createSyntheticStage(at: stage)
      let trustedDigest = try SQLiteStagingStore().contentDigest(at: stage)
      try withWritableDatabase(stage) { database in
        try execute(
          database,
          "UPDATE staged_table SET table_name='attacker-recomputed' WHERE table_id='\(hexID("b"))'")
      }
      try rewriteDigest(at: stage)

      #expect(throws: ReconciliationError.invalidStagingDatabase) {
        try reconcileStage(
          stage, decisions: [], expectedContentDigest: trustedDigest)
      }
    }
  }

  @Test("symlinks and SQLite companion files are rejected")
  func unstableFileIdentityBlocks() throws {
    try withReconciliationDirectory { directory in
      let target = directory.appendingPathComponent("target.sqlite")
      let link = directory.appendingPathComponent("link.sqlite")
      try createSyntheticStage(at: target)
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

      #expect(throws: ReconciliationError.invalidStagingDatabase) {
        try reconcileStage(link, decisions: [])
      }

      let companion = URL(fileURLWithPath: target.path + "-wal")
      #expect(FileManager.default.createFile(atPath: companion.path, contents: Data()))
      #expect(throws: ReconciliationError.invalidStagingDatabase) {
        try reconcileStage(target, decisions: [])
      }
    }
  }

  @Test("rename-swap races use the pinned database and fail final identity")
  func renameSwapUsesPinnedDatabase() throws {
    try withReconciliationDirectory { directory in
      let stage = directory.appendingPathComponent("stage.sqlite")
      let alternate = directory.appendingPathComponent("alternate.sqlite")
      let parked = directory.appendingPathComponent("parked.sqlite")
      try createSyntheticStage(at: stage)
      try createSyntheticStage(at: alternate, hostileText: "alternate-safe-value")
      let expectedDigest = try SQLiteStagingStore().contentDigest(at: stage)
      let stagePath = stage.path
      let alternatePath = alternate.path
      let parkedPath = parked.path
      let reconciler = StagingReconciler(
        testingAfterDatabaseOpen: {
          #expect(rename(stagePath, parkedPath) == 0)
          #expect(rename(alternatePath, stagePath) == 0)
        },
        testingBeforeFinalIdentity: {
          #expect(rename(stagePath, alternatePath) == 0)
          #expect(rename(parkedPath, stagePath) == 0)
        })

      #expect(throws: ReconciliationError.invalidStagingDatabase) {
        try reconciler.reconcile(
          stagingDatabaseURL: stage,
          expectedManifest: syntheticManifest(),
          expectedContentDigest: expectedDigest,
          decisions: [])
      }
      var parkedStatus = stat()
      if lstat(parkedPath, &parkedStatus) == 0 {
        #expect(rename(stagePath, alternatePath) == 0)
        #expect(rename(parkedPath, stagePath) == 0)
      }
      #expect(try SQLiteStagingStore().contentDigest(at: stage) == expectedDigest)
    }
  }

  @Test("empty, non-text, non-canonical identifiers and invalid storage types are rejected")
  func invalidIdentifiersAndTypesBlock() throws {
    try withReconciliationDirectory { directory in
      let mutations = [
        "UPDATE staged_field SET field_id=''",
        "UPDATE staged_field SET field_id=X'00'",
        "UPDATE staged_field SET field_id='abc'",
        "UPDATE staged_table SET ordinal='not-an-integer' WHERE table_id='\(hexID("b"))'",
        "UPDATE staged_field SET storage_class='integer'",
      ]
      for (index, mutation) in mutations.enumerated() {
        let stage = directory.appendingPathComponent("invalid-\(index).sqlite")
        try createSyntheticStage(at: stage)
        try withWritableDatabase(stage) { database in
          try execute(database, mutation)
        }
        try rewriteDigest(at: stage)

        #expect(throws: ReconciliationError.invalidStagingDatabase) {
          try reconcileStage(stage, decisions: [])
        }
      }
    }
  }

  @Test("declared manifest hierarchy count drift blocks zero loss")
  func countMismatchBlocks() throws {
    try withReconciliationDirectory { directory in
      let stage = directory.appendingPathComponent("count-mismatch.sqlite")
      try createSyntheticStage(at: stage)
      try withWritableDatabase(stage) { database in
        try execute(
          database,
          "UPDATE staged_table SET record_count=0 WHERE table_id='\(hexID("b"))'")
      }
      try rewriteDigest(at: stage)

      let report = try reconcileStage(
        stage,
        decisions: [
          ReconciliationDecision(
            subjectID: hexID("a"), kind: .artifact, disposition: .preserved,
            reasonCode: "immutable_source_provenance",
            evidence: try evidence(
              for: .preserved, subjectID: hexID("a"), kind: .artifact, stage: stage)),
          ReconciliationDecision(
            subjectID: hexID("b"), kind: .table, disposition: .mapped,
            reasonCode: "known_table_adapter",
            evidence: try evidence(
              for: .mapped, subjectID: hexID("b"), kind: .table, stage: stage)),
          ReconciliationDecision(
            subjectID: hexID("c"), kind: .record, disposition: .mapped,
            reasonCode: "known_record_adapter",
            evidence: try evidence(
              for: .mapped, subjectID: hexID("c"), kind: .record, stage: stage)),
          ReconciliationDecision(
            subjectID: hexID("d"), kind: .field, disposition: .preserved,
            reasonCode: "tombstone_preserved",
            evidence: try evidence(
              for: .preserved, subjectID: hexID("d"), kind: .field, stage: stage)),
          ReconciliationDecision(
            subjectID: hexID("e"), kind: .table, disposition: .excluded,
            reasonCode: "adapter_metadata_table",
            evidence: try evidence(
              for: .excluded, subjectID: hexID("e"), kind: .table, stage: stage)),
        ])

      #expect(report.blockingCount == 1)
      #expect(report.entries.contains { $0.reasonCode == .countMismatch })
      #expect(throws: ReconciliationError.expectZeroLossFailed) {
        try report.requireZeroLoss()
      }
    }
  }
}

private func hexID(_ character: Character) -> String {
  String(repeating: String(character), count: 64)
}

private func publicClientTypechecks(_ expression: String) throws -> Bool {
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  let build = root.appendingPathComponent(".build", isDirectory: true)
  guard
    let enumerator = FileManager.default.enumerator(
      at: build, includingPropertiesForKeys: nil)
  else { throw ReconciliationTestFailure.io }
  var modules: URL?
  var moduleMap: URL?
  while let candidate = enumerator.nextObject() as? URL {
    if candidate.lastPathComponent == "MMImport.swiftmodule" {
      modules = candidate.deletingLastPathComponent()
    } else if isCSQLiteModuleMap(candidate) {
      moduleMap = candidate
    }
  }
  guard let modules, let moduleMap else { throw ReconciliationTestFailure.io }
  #if arch(arm64)
    let architecture = "arm64"
  #else
    let architecture = "x86_64"
  #endif
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "ledger-atlas-public-api-test-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("Client.swift")
  try Data("import MMImport\n\(expression)\n".utf8).write(to: source)
  let sdk = try processOutput("/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-path"])
    .trimmingCharacters(in: .whitespacesAndNewlines)
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
  process.arguments = [
    "swiftc", "-typecheck", "-sdk", sdk, "-target", "\(architecture)-apple-macosx15.0",
    "-I", modules.path, "-Xcc", "-fmodule-map-file=\(moduleMap.path)", source.path,
  ]
  process.standardOutput = Pipe()
  process.standardError = Pipe()
  try process.run()
  process.waitUntilExit()
  return process.terminationStatus == 0
}

/// SwiftPM puts the generated CSQLite module map in different places depending on the
/// build system: `.build/<triple>/debug/CSQLite.build/module.modulemap` (classic) or
/// `.build/out/Intermediates.noindex/GeneratedModuleMaps/CSQLite.modulemap` (Xcode 27+).
private func isCSQLiteModuleMap(_ candidate: URL) -> Bool {
  if candidate.lastPathComponent == "CSQLite.modulemap" { return true }
  return candidate.lastPathComponent == "module.modulemap"
    && candidate.path.contains("CSQLite.build")
}

private func processOutput(_ executable: String, _ arguments: [String]) throws -> String {
  let process = Process()
  let output = Pipe()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  process.standardOutput = output
  process.standardError = Pipe()
  try process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else { throw ReconciliationTestFailure.io }
  return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

private func withReconciliationDirectory(_ body: (URL) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "ledger-atlas-reconciliation-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: directory) }
  try body(directory)
}

private func createSyntheticStage(
  at url: URL,
  orphanRecord: Bool = false,
  hostileText: String = "synthetic-safe-value",
  literalWhitespaceDrift: Bool = false
) throws {
  try withWritableDatabase(url) { database in
    let fieldCount = 1
    let opaqueByteCount = hostileText.utf8.count
    let nullStorageLiteral = literalWhitespaceDrift ? "null " : "null"
    let statements = [
      "CREATE TABLE staging_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)",
      "CREATE TABLE staged_artifact(artifact_id TEXT PRIMARY KEY, artifact_sha256 TEXT NOT NULL, profile_id TEXT NOT NULL, adapter_version TEXT NOT NULL, source_size_bytes INTEGER NOT NULL CHECK(source_size_bytes >= 0))",
      "CREATE TABLE staged_table(table_id TEXT PRIMARY KEY, artifact_id TEXT NOT NULL REFERENCES staged_artifact(artifact_id), ordinal INTEGER NOT NULL CHECK(ordinal >= 0), table_name TEXT NOT NULL, record_count INTEGER NOT NULL CHECK(record_count >= 0), UNIQUE(artifact_id, ordinal), UNIQUE(artifact_id, table_name))",
      "CREATE TABLE staged_record(record_id TEXT PRIMARY KEY, table_id TEXT NOT NULL REFERENCES staged_table(table_id), record_key TEXT NOT NULL, field_count INTEGER NOT NULL CHECK(field_count >= 0), opaque_byte_count INTEGER NOT NULL CHECK(opaque_byte_count >= 0), UNIQUE(table_id, record_key))",
      "CREATE TABLE staged_field(field_id TEXT PRIMARY KEY, record_id TEXT NOT NULL REFERENCES staged_record(record_id), ordinal INTEGER NOT NULL CHECK(ordinal >= 0), column_name TEXT NOT NULL, declared_type TEXT, storage_class TEXT NOT NULL CHECK(storage_class IN ('\(nullStorageLiteral)', 'integer', 'real', 'blob', 'text')), payload BLOB NOT NULL, sidecar_version INTEGER NOT NULL CHECK(sidecar_version = 1), container_member TEXT, UNIQUE(record_id, ordinal))",
      "CREATE TABLE staging_manifest(format_version INTEGER NOT NULL CHECK(format_version = 1), staging_id TEXT PRIMARY KEY REFERENCES staged_artifact(artifact_id), artifact_sha256 TEXT NOT NULL, profile_id TEXT NOT NULL, adapter_version TEXT NOT NULL, table_count INTEGER NOT NULL CHECK(table_count >= 0), record_count INTEGER NOT NULL CHECK(record_count >= 0), field_count INTEGER NOT NULL CHECK(field_count >= 0), opaque_byte_count INTEGER NOT NULL CHECK(opaque_byte_count >= 0))",
      "INSERT INTO staging_meta VALUES('format_version', '1')",
      "INSERT INTO staging_meta VALUES('staging_id', '\(hexID("a"))')",
      "INSERT INTO staging_meta VALUES('limits_description', 'synthetic-limits-v1')",
      "INSERT INTO staged_artifact VALUES('\(hexID("a"))', '\(hexID("f"))', 'synthetic-profile', 'synthetic-adapter', 1)",
      "INSERT INTO staged_table VALUES('\(hexID("b"))', '\(hexID("a"))', 0, '\(hostileText)', 1)",
      "INSERT INTO staged_table VALUES('\(hexID("e"))', '\(hexID("a"))', 1, 'synthetic-metadata', 0)",
      "INSERT INTO staged_record VALUES('\(hexID("c"))', '\(orphanRecord ? hexID("f") : hexID("b"))', 'synthetic-record', \(fieldCount), \(opaqueByteCount))",
      "INSERT INTO staged_field VALUES('\(hexID("d"))', '\(hexID("c"))', 0, '\(hostileText)', 'TEXT', 'text', CAST('\(hostileText)' AS BLOB), 1, NULL)",
      "INSERT INTO staging_manifest VALUES(1, '\(hexID("a"))', '\(hexID("f"))', 'synthetic-profile', 'synthetic-adapter', 2, 1, \(fieldCount), \(opaqueByteCount))",
    ]
    for statement in statements {
      try execute(database, statement)
    }
  }
  try rewriteDigest(at: url)
}

private func syntheticManifest(
  opaqueByteCount: Int = "synthetic-safe-value".utf8.count
) -> StagingManifest {
  StagingManifest(
    formatVersion: 1,
    stagingID: hexID("a"),
    artifactSHA256: hexID("f"),
    profileID: "synthetic-profile",
    adapterVersion: "synthetic-adapter",
    tableCount: 2,
    recordCount: 1,
    fieldCount: 1,
    opaqueByteCount: opaqueByteCount)
}

private func reconcileStage(
  _ url: URL,
  decisions: [ReconciliationDecision],
  expectedManifest: StagingManifest = syntheticManifest(),
  expectedContentDigest: String? = nil
) throws -> ReconciliationReport {
  try StagingReconciler().reconcile(
    stagingDatabaseURL: url,
    expectedManifest: expectedManifest,
    expectedContentDigest: try expectedContentDigest
      ?? SQLiteStagingStore().contentDigest(at: url),
    decisions: decisions)
}

private func evidence(
  for disposition: ReconciliationDisposition,
  subjectID: String,
  kind: ReconciliationSubjectKind,
  stage: URL
) throws -> ReconciliationEvidence? {
  let stageDigest = try SQLiteStagingStore().contentDigest(at: stage)
  return targetEvidence(
    stageDigest: stageDigest, subjectID: subjectID, kind: kind, disposition: disposition,
    targetComponents: ["synthetic-target", disposition.rawValue])
}

private func targetEvidence(
  stageDigest: String,
  subjectID: String,
  kind: ReconciliationSubjectKind,
  disposition: ReconciliationDisposition,
  targetComponents: [String]
) -> ReconciliationEvidence? {
  let proof = TargetBoundReconciliationProof(
    stageDigest: stageDigest, subjectID: subjectID, kind: kind, disposition: disposition,
    targetComponents: targetComponents)
  return switch disposition {
  case .mapped: ReconciliationEvidence.canonicalMapping(proof)
  case .preserved: ReconciliationEvidence.opaquePreservation(proof)
  case .excluded: ReconciliationEvidence.intentionalExclusion(proof)
  case .blocked: nil
  }
}

private func rewriteDigest(at url: URL) throws {
  let digest = try SQLiteStagingStore().contentDigest(at: url)
  try withWritableDatabase(url) { database in
    try execute(database, "DELETE FROM staging_meta WHERE key='content_digest'")
    try execute(
      database,
      "INSERT INTO staging_meta VALUES('content_digest', '\(digest)')")
  }
}

private func withWritableDatabase(
  _ url: URL,
  _ body: (OpaquePointer) throws -> Void
) throws {
  var database: OpaquePointer?
  guard
    sqlite3_open_v2(
      url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
    let database
  else { throw ReconciliationTestFailure.sqlite }
  defer { sqlite3_close(database) }
  try body(database)
}

private func execute(_ database: OpaquePointer, _ sql: String) throws {
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
    throw ReconciliationTestFailure.sqlite
  }
}

private enum ReconciliationTestFailure: Error { case sqlite, io }
