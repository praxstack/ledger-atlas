import Darwin
import Foundation
import LedgerCore
import MMImport

private let usageExit: Int32 = 64
private let dataExit: Int32 = 65
private let operationExit: Int32 = 4
private let zeroLossExit: Int32 = 5

private enum CLIInputError: Error {
  case invalidArguments
  case invalidFile
  case invalidJSON
  case invalidPlan
}

private struct ParsedOptions {
  let values: [String: String]
  let flags: Set<String>
}

private struct DecisionEnvelope: Decodable {
  let formatVersion: Int
  let decisions: [DecisionDescriptor]

  func validated() throws -> [ReconciliationDecision] {
    guard formatVersion == 1, decisions.count <= 1_000_000 else {
      throw CLIInputError.invalidPlan
    }
    return try decisions.map { try $0.validated() }
  }
}

private struct DecisionDescriptor: Decodable {
  let subjectID: String
  let kind: ReconciliationSubjectKind
  let disposition: ReconciliationDisposition
  let reasonCode: String

  func validated() throws -> ReconciliationDecision {
    guard subjectID.utf8.count == 64,
      subjectID.utf8.allSatisfy({
        ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
      }),
      !reasonCode.isEmpty, reasonCode.utf8.count <= 64
    else { throw CLIInputError.invalidPlan }
    return ReconciliationDecision(
      subjectID: subjectID, kind: kind, disposition: disposition,
      reasonCode: reasonCode)
  }
}

private struct CanonicalPlan: Decodable {
  let formatVersion: Int
  let canonicalDatabase: String
  let stagingDatabase: String
  let manifest: StagingManifest
  let stagingDigest: String
  let mappingDecisions: [DecisionDescriptor]
  let events: [CanonicalEconomicEvent]

  func request() throws -> CanonicalCommitRequest {
    guard formatVersion == 1,
      Self.validAbsolutePath(canonicalDatabase), Self.validAbsolutePath(stagingDatabase),
      mappingDecisions.count <= 1_000_000, events.count <= 100_000
    else { throw CLIInputError.invalidPlan }
    let validatedEvents = try events.map(Self.validatedEvent)
    return CanonicalCommitRequest(
      canonicalDatabaseURL: URL(fileURLWithPath: canonicalDatabase),
      stagingDatabaseURL: URL(fileURLWithPath: stagingDatabase),
      expectedManifest: manifest,
      expectedStagingDigest: stagingDigest,
      mappingDecisions: try mappingDecisions.map { try $0.validated() },
      events: validatedEvents)
  }

  fileprivate static func validAbsolutePath(_ value: String) -> Bool {
    value.hasPrefix("/") && value.utf8.count <= 4_096
  }

  private static func validatedEvent(
    _ event: CanonicalEconomicEvent
  ) throws -> CanonicalEconomicEvent {
    let bindings = try event.sourceBindings.map {
      try CanonicalEventSourceBinding(
        semantic: $0.semantic, provenance: $0.provenance,
        declaredType: $0.declaredType, storageClass: $0.storageClass)
    }
    let sidecars = try event.sidecarReferences.map {
      try CanonicalSidecarReference(
        sidecarID: $0.sidecarID, provenanceID: $0.provenanceID)
    }
    return try CanonicalEconomicEvent(
      eventID: event.eventID, accountID: event.accountID, kind: event.kind,
      amount: event.amount, occurredAt: event.occurredAt,
      sourceRecordID: event.sourceRecordID,
      amountProvenance: event.amountProvenance,
      sourceBindings: bindings, sidecarReferences: sidecars)
  }
}

/// Bounded observed-v19 input: events, mappings, IDs, and UTC instants are adapter-derived.
private struct ObservedV19Plan: Decodable {
  let formatVersion: Int
  let canonicalDatabase: String
  let stagingDatabase: String
  let manifest: StagingManifest
  let stagingDigest: String
  let sourceTimeZone: SourceTimeZone

  func request() throws -> CanonicalCommitRequest {
    guard formatVersion == 1,
      CanonicalPlan.validAbsolutePath(canonicalDatabase),
      CanonicalPlan.validAbsolutePath(stagingDatabase)
    else { throw CLIInputError.invalidPlan }
    return try MoneyManagerV19Adapter.canonicalCommitRequest(
      canonicalDatabaseURL: URL(fileURLWithPath: canonicalDatabase),
      stagingDatabaseURL: URL(fileURLWithPath: stagingDatabase),
      expectedManifest: manifest, expectedContentDigest: stagingDigest,
      sourceTimeZone: sourceTimeZone)
  }
}

private struct FailureReport: Encodable {
  let reportVersion = 1
  let status = "blocked"
  let reasonCodes: [String]

  var humanDescription: String {
    "status=blocked\nreasons=\(reasonCodes.joined(separator: ","))"
  }
}

/// Explicit coverage output contains fingerprints and structural diagnostics only.
private struct CoverageReport: Encodable {
  let reportVersion = 1
  let receiptVersion: Int?
  let status: ClassificationStatus
  let sourceSHA256Before: String?
  let sourceSHA256After: String?
  let profileID: String?
  let schemaSHA256: String?
  let tableCount: Int?
  let indexCount: Int?
  let structuralCoverage: SourceStructuralCoverage?
  let diagnosticCodes: [ClassificationDiagnostic]
  let reasonCodes: [String]

  init(receipt: CompatibilityCoverageReceipt, result: ClassificationResult) {
    receiptVersion = receipt.receiptVersion
    status = receipt.status
    sourceSHA256Before = result.fingerprintBefore?.sha256
    sourceSHA256After = result.fingerprintAfter?.sha256
    profileID = receipt.profileID
    schemaSHA256 = receipt.schemaSHA256
    tableCount = receipt.tableCount
    indexCount = receipt.indexCount
    structuralCoverage = receipt.structuralCoverage
    diagnosticCodes = receipt.diagnosticCodes
    reasonCodes = []
  }

  init(failed result: ClassificationResult) {
    receiptVersion = nil
    status = result.status
    sourceSHA256Before = result.fingerprintBefore?.sha256
    sourceSHA256After = result.fingerprintAfter?.sha256
    profileID = nil
    schemaSHA256 = nil
    tableCount = nil
    indexCount = nil
    structuralCoverage = nil
    diagnosticCodes = result.diagnostics.sorted { $0.rawValue < $1.rawValue }
    reasonCodes = ["invalid_coverage_receipt"]
  }

  var humanDescription: String {
    [
      "status=\(status.rawValue)",
      "source_sha256_before=\(sourceSHA256Before ?? "none")",
      "source_sha256_after=\(sourceSHA256After ?? "none")",
      "profile=\(profileID ?? "none")",
      "diagnostics=\(diagnosticCodes.map(\.rawValue).joined(separator: ","))",
      "reasons=\(reasonCodes.isEmpty ? "none" : reasonCodes.joined(separator: ","))",
    ].joined(separator: "\n")
  }
}

private struct CommitReport: Encodable {
  let reportVersion = 1
  let status: String
  let eventCount: Int?
  let canonicalChecksum: String?
  let reconciliationHash: String?
  let reasonCodes: [String]

  init(_ result: CanonicalCommitResult) {
    status = result.status.rawValue
    eventCount = result.eventCount
    canonicalChecksum = result.canonicalChecksum
    reconciliationHash = result.reconciliationHash
    reasonCodes = []
  }

  init(error: CanonicalCommitError) {
    status = "blocked"
    eventCount = nil
    canonicalChecksum = nil
    reconciliationHash = nil
    reasonCodes = [error.rawValue]
  }

  init(reasonCode: String) {
    status = "blocked"
    eventCount = nil
    canonicalChecksum = nil
    reconciliationHash = nil
    reasonCodes = [reasonCode]
  }

  var humanDescription: String {
    [
      "status=\(status)",
      "events=\(eventCount.map(String.init) ?? "none")",
      "canonical_checksum=\(canonicalChecksum ?? "none")",
      "reconciliation_hash=\(reconciliationHash ?? "none")",
      "reasons=\(reasonCodes.isEmpty ? "none" : reasonCodes.joined(separator: ","))",
    ].joined(separator: "\n")
  }
}

private func parseOptions(
  _ arguments: ArraySlice<String>,
  valueNames: Set<String>,
  flagNames: Set<String>
) throws -> ParsedOptions {
  guard arguments.count <= (valueNames.count * 2 + flagNames.count) else {
    throw CLIInputError.invalidArguments
  }
  var values: [String: String] = [:]
  var flags: Set<String> = []
  var index = arguments.startIndex
  while index < arguments.endIndex {
    let option = arguments[index]
    if flagNames.contains(option) {
      guard flags.insert(option).inserted else { throw CLIInputError.invalidArguments }
      index = arguments.index(after: index)
    } else if valueNames.contains(option) {
      guard values[option] == nil else { throw CLIInputError.invalidArguments }
      let valueIndex = arguments.index(after: index)
      guard valueIndex < arguments.endIndex, !arguments[valueIndex].hasPrefix("--") else {
        throw CLIInputError.invalidArguments
      }
      values[option] = arguments[valueIndex]
      index = arguments.index(after: valueIndex)
    } else {
      throw CLIInputError.invalidArguments
    }
  }
  return ParsedOptions(values: values, flags: flags)
}

private func readBoundedJSON<T: Decodable>(
  _ type: T.Type, path: String, maximumBytes: Int
) throws -> T {
  guard path.utf8.count <= 4_096 else { throw CLIInputError.invalidFile }
  let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
  guard descriptor >= 0 else { throw CLIInputError.invalidFile }
  defer { Darwin.close(descriptor) }
  var attributes = stat()
  guard fstat(descriptor, &attributes) == 0,
    (attributes.st_mode & S_IFMT) == S_IFREG,
    attributes.st_size >= 0, attributes.st_size <= maximumBytes
  else { throw CLIInputError.invalidFile }

  var data = Data()
  data.reserveCapacity(Int(attributes.st_size))
  var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
  while true {
    let count = Darwin.read(descriptor, &buffer, buffer.count)
    guard count >= 0 else { throw CLIInputError.invalidFile }
    if count == 0 { break }
    guard data.count <= maximumBytes - count else { throw CLIInputError.invalidFile }
    data.append(buffer, count: count)
  }
  guard data.count == Int(attributes.st_size) else { throw CLIInputError.invalidFile }
  do { return try JSONDecoder().decode(type, from: data) } catch { throw CLIInputError.invalidJSON }
}

private func writeJSON<T: Encodable>(_ value: T) throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  FileHandle.standardOutput.write(try encoder.encode(value))
  FileHandle.standardOutput.write(Data("\n".utf8))
}

private func writeHuman(_ value: String) {
  FileHandle.standardOutput.write(Data((value + "\n").utf8))
}

private func writeUsage(_ value: String) -> Never {
  FileHandle.standardError.write(Data((value + "\n").utf8))
  exit(usageExit)
}

private func runInspect(_ arguments: [String], command: String) -> Never {
  guard arguments.count == 2 || arguments.count == 3,
    arguments[0] == command,
    arguments.count != 3 || arguments[2] == "--json"
  else { writeUsage("usage: mmctl \(command) <path> [--json]") }
  let result = SourceClassifier().classify(URL(fileURLWithPath: arguments[1]))
  let report = RedactedClassificationReport(result)
  if arguments.last == "--json" {
    do { try writeJSON(report) } catch { exit(70) }
  } else {
    writeHuman(report.humanDescription)
  }
  exit(result.suggestedExitCode)
}

private func runCoverage(_ arguments: [String]) -> Never {
  guard arguments.count == 2 || arguments.count == 3,
    arguments[0] == "coverage", arguments.count != 3 || arguments[2] == "--json"
  else { writeUsage("usage: mmctl coverage <path> [--json]") }
  let result = SourceClassifier(collectStructuralCoverage: true).classify(
    URL(fileURLWithPath: arguments[1]))
  do {
    let receipt = try CompatibilityCoverageReceipt(result)
    let report = CoverageReport(receipt: receipt, result: result)
    if arguments.last == "--json" {
      try writeJSON(report)
    } else {
      writeHuman(report.humanDescription)
    }
    exit(result.suggestedExitCode)
  } catch {
    let report = CoverageReport(failed: result)
    if arguments.last == "--json" {
      try? writeJSON(report)
    } else {
      writeHuman(report.humanDescription)
    }
    exit(operationExit)
  }
}

private func runStage(_ arguments: [String]) -> Never {
  guard arguments.count == 5 || arguments.count == 6,
    arguments[1] == "--input", arguments[3] == "--staging-db",
    arguments.count != 6 || arguments[5] == "--json"
  else { writeUsage("usage: mmctl stage --input <path> --staging-db <path> [--json]") }
  let json = arguments.last == "--json"
  let report: RedactedStagingReport
  let exitCode: Int32
  do {
    let result = try ImmutableSourceStager().stage(
      StagingRequest(
        sourceURL: URL(fileURLWithPath: arguments[2]),
        stagingDatabaseURL: URL(fileURLWithPath: arguments[4])))
    report = RedactedStagingReport(result)
    exitCode = 0
  } catch let error as StagingError {
    report = RedactedStagingReport(error: error)
    exitCode = operationExit
  } catch {
    report = RedactedStagingReport(error: .stagingWriteFailed)
    exitCode = 70
  }
  if json {
    do { try writeJSON(report) } catch { exit(70) }
  } else {
    writeHuman(report.humanDescription)
  }
  exit(exitCode)
}

private func runReconcile(_ arguments: [String]) -> Never {
  let usage =
    "usage: mmctl reconcile (--staging-db <path> --manifest <json-file> --digest <sha256> --decisions <json-file> | --request <json-file> | --observed-v19-request <json-file>) [--expect-zero-loss] [--json]"
  let parsed: ParsedOptions
  do {
    parsed = try parseOptions(
      arguments.dropFirst(),
      valueNames: [
        "--staging-db", "--manifest", "--digest", "--decisions", "--request",
        "--observed-v19-request",
      ],
      flagNames: ["--expect-zero-loss", "--json"])
  } catch { writeUsage(usage) }
  let json = parsed.flags.contains("--json")

  do {
    let report: ReconciliationReport
    if parsed.values.count == 1, let requestPath = parsed.values["--request"] {
      let plan = try readBoundedJSON(
        CanonicalPlan.self, path: requestPath, maximumBytes: 32 * 1_024 * 1_024)
      report = try SQLiteCanonicalCommitter().prepare(plan.request())
    } else if parsed.values.count == 1,
      let requestPath = parsed.values["--observed-v19-request"]
    {
      let plan = try readBoundedJSON(
        ObservedV19Plan.self, path: requestPath, maximumBytes: 128 * 1_024)
      report = try SQLiteCanonicalCommitter().prepare(plan.request())
    } else if parsed.values.count == 4,
      let stagingPath = parsed.values["--staging-db"],
      let manifestPath = parsed.values["--manifest"],
      let digest = parsed.values["--digest"],
      let decisionsPath = parsed.values["--decisions"]
    {
      let manifest = try readBoundedJSON(
        StagingManifest.self, path: manifestPath, maximumBytes: 64 * 1_024)
      let envelope = try readBoundedJSON(
        DecisionEnvelope.self, path: decisionsPath, maximumBytes: 16 * 1_024 * 1_024)
      report = try StagingReconciler().reconcile(
        stagingDatabaseURL: URL(fileURLWithPath: stagingPath),
        expectedManifest: manifest, expectedContentDigest: digest,
        decisions: try envelope.validated())
    } else {
      writeUsage(usage)
    }
    if json { try writeJSON(report) } else { writeHuman(report.humanDescription) }
    if parsed.flags.contains("--expect-zero-loss"), report.blockingCount != 0 {
      exit(zeroLossExit)
    }
    exit(0)
  } catch let error as ReconciliationError {
    let report = FailureReport(reasonCodes: [error.rawValue])
    if json { try? writeJSON(report) } else { writeHuman(report.humanDescription) }
    exit(operationExit)
  } catch {
    let report = FailureReport(reasonCodes: ["invalid_reconciliation_request"])
    if json { try? writeJSON(report) } else { writeHuman(report.humanDescription) }
    exit(dataExit)
  }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
  print(
    "mmctl schema=\(LedgerCoreVersion.current) importer=\(ImportCapability.canonicalSchemaVersion)")
  exit(0)
}

private func runCertify(_ arguments: [String]) -> Never {
  let usage =
    "usage: mmctl certify --input <backup> --work-dir <empty-dir> --time-zone <iana-id|fixed:SECONDS> --locale <locale> [--oracle <json-file>] [--json]"
  let parsed: ParsedOptions
  do {
    parsed = try parseOptions(
      arguments.dropFirst(),
      valueNames: ["--input", "--work-dir", "--time-zone", "--locale", "--oracle"],
      flagNames: ["--json"])
  } catch { writeUsage(usage) }
  guard let input = parsed.values["--input"], let work = parsed.values["--work-dir"],
    let zone = parsed.values["--time-zone"], let locale = parsed.values["--locale"]
  else { writeUsage(usage) }
  let timeZone: SourceTimeZone
  do {
    if zone.hasPrefix("fixed:"), let seconds = Int(zone.dropFirst("fixed:".count)) {
      timeZone = try SourceTimeZone(fixedOffsetSeconds: seconds)
    } else {
      timeZone = try SourceTimeZone(ianaIdentifier: zone)
    }
  } catch { writeUsage(usage) }
  // The scratch ledgers go in a directory the caller made for them, so nothing is overwritten.
  guard let entries = try? FileManager.default.contentsOfDirectory(atPath: work), entries.isEmpty
  else {
    FileHandle.standardError.write(Data("mmctl certify: --work-dir must be an empty directory\n".utf8))
    exit(dataExit)
  }
  do {
    let oracle = try parsed.values["--oracle"].map {
      try readBoundedJSON(MoneyManagerV19AggregateOracle.self, path: $0, maximumBytes: 64 * 1_024)
    }
    let certificate = try MoneyManagerV19ImportCertifier.certify(
      sourceURL: URL(fileURLWithPath: input), workDirectory: URL(fileURLWithPath: work),
      sourceTimeZone: timeZone, locale: locale, oracle: oracle)
    if parsed.flags.contains("--json") {
      try writeJSON(certificate)
    } else {
      let failed = certificate.checks.filter { !$0.passed }.map(\.name)
      writeHuman(
        "level=\(certificate.achievedLevel.rawValue) source=\(certificate.sourceSHA256) profile=\(certificate.profileID) events=\(certificate.eventCount) transfer_pairs=\(certificate.transferPairs) failed=\(failed.isEmpty ? "none" : failed.joined(separator: ","))"
      )
    }
    exit(certificate.checks.allSatisfy(\.passed) ? 0 : zeroLossExit)
  } catch {
    // Error codes only: never a path or a value from the backup.
    let code = (error as? MoneyManagerV19ImportCertifierError).map { String(describing: $0) } ?? "import_failed"
    FileHandle.standardError.write(Data("mmctl certify: \(code)\n".utf8))
    exit(operationExit)
  }
}

switch command {
case "inspect", "classify": runInspect(arguments, command: command)
case "coverage": runCoverage(arguments)
case "stage": runStage(arguments)
case "reconcile": runReconcile(arguments)
case "certify": runCertify(arguments)
default:
  writeUsage("usage: mmctl <inspect|classify|coverage|stage|reconcile|certify> ...")
}
