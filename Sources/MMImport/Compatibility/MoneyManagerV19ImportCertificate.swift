import CSQLite
import Foundation
import LedgerCore

/// Expected aggregates for one named backup, written by whoever holds the backup. Counts only:
/// an oracle never carries rows, names or amounts.
public struct MoneyManagerV19AggregateOracle: Codable, Equatable, Sendable {
  /// Canonical event kind (income, expense, transfer_debit, ...) to the expected event count.
  public let eventsByKind: [String: Int]
  public let transferPairs: Int

  public init(eventsByKind: [String: Int], transferPairs: Int) {
    self.eventsByKind = eventsByKind
    self.transferPairs = transferPairs
  }

  /// Names the oracle by its content, so a certificate points at exactly the expectations used.
  public var oracleID: String {
    let kinds = eventsByKind.keys.sorted().flatMap { [$0, String(eventsByKind[$0]!)] }
    return "aggregate-oracle:"
      + CanonicalReceiptDigest.hash(
        ["ledger-atlas/mm-v19-aggregate-oracle/v1", String(transferPairs)] + kinds)
  }
}

/// A named certificate for one import of one exact backup. Every field is an aggregate or a hash,
/// so it can be shared without exposing the ledger. The level is derived from the checks that
/// passed; a caller cannot ask for one.
public struct MoneyManagerV19ImportCertificate: Codable, Equatable, Sendable {
  public static let version = 1

  public struct Check: Codable, Equatable, Sendable {
    public let name: String
    public let passed: Bool
  }

  public let certificateVersion: Int
  public let sourceSHA256: String
  public let sourceByteCount: Int
  public let container: String
  public let profileID: String
  public let adapterVersion: String
  public let locale: String
  public let sourceTimeZone: String
  public let oracleID: String?
  public let achievedLevel: CompatibilityLevel
  public let tableCount: Int
  public let recordCount: Int
  public let fieldCount: Int
  public let mappedCount: Int
  public let preservedCount: Int
  public let excludedCount: Int
  public let eventCount: Int
  public let eventsByKind: [String: Int]
  public let transferPairs: Int
  public let eventSetHash: String
  public let reconciliationHash: String
  public let checks: [Check]
}

public enum MoneyManagerV19ImportCertifierError: Error, Equatable, Sendable {
  case unsupportedLocale
  case notPrepared(String)
  case unreadableSource
  case unreadableCanonical
}

/// Imports one backup into scratch ledgers inside `workDirectory` and certifies what happened.
/// The source is only read; the scratch ledgers are left for inspection.
public enum MoneyManagerV19ImportCertifier {
  public static func certify(
    sourceURL: URL,
    workDirectory: URL,
    sourceTimeZone: SourceTimeZone,
    locale: String,
    oracle: MoneyManagerV19AggregateOracle?
  ) throws -> MoneyManagerV19ImportCertificate {
    guard CompatibilityCorpus.locales.contains(locale) else {
      throw MoneyManagerV19ImportCertifierError.unsupportedLocale
    }
    let before = try sourceDigest(sourceURL)
    let workspace = ImportWorkspace()
    func runImport(_ name: String, canonical: URL) throws -> (
      ImportWorkspace.Review, ImportWorkspace.CommitResult
    ) {
      let preparation = try workspace.prepare(
        .init(
          sourceURL: sourceURL,
          stagingDatabaseURL: workDirectory.appendingPathComponent("\(name)-stage.sqlite"),
          canonicalDatabaseURL: canonical, sourceTimeZone: sourceTimeZone))
      guard let handle = preparation.preparedHandle else {
        throw MoneyManagerV19ImportCertifierError.notPrepared(
          preparation.review.diagnosticCodes.joined(separator: ","))
      }
      return (preparation.review, try workspace.commit(handle, approval: workspace.approve(handle)))
    }

    let first = workDirectory.appendingPathComponent("certify-a.sqlite")
    let second = workDirectory.appendingPathComponent("certify-b.sqlite")
    let (review, committed) = try runImport("a", canonical: first)
    let (_, repeated) = try runImport("a-again", canonical: first)
    let (_, independent) = try runImport("b", canonical: second)
    let after = try sourceDigest(sourceURL)

    let ledgerA = try CanonicalAggregates(first)
    let ledgerB = try CanonicalAggregates(second)

    let mapped = review.mappedCount ?? -1
    let preserved = review.preservedCount ?? -1
    let excluded = review.excludedCount ?? -1
    let subjects = (review.tableCount ?? 0) + (review.recordCount ?? 0) + (review.fieldCount ?? 0)
    var checks: [MoneyManagerV19ImportCertificate.Check] = []
    func check(_ name: String, _ passed: Bool) { checks.append(.init(name: name, passed: passed)) }

    // L2: the exact bytes, read without change, every staged subject has a disposition and
    // nothing blocks or is left unresolved.
    check("source_unchanged", before == after)
    check("profile_observed_v19", review.classificationStatus == .supported)
    check("committed", committed.status == .committed && committed.eventCount == ledgerA.eventCount)
    check("no_blocking_subjects", review.blockingCount == 0)
    check("no_unresolved_semantics", review.unresolvedSemanticCount == 0)
    // Every table, record and field, plus the source artifact itself, has exactly one disposition.
    check(
      "every_subject_dispositioned",
      mapped >= 0 && preserved >= 0 && excluded >= 0 && mapped + preserved + excluded == subjects + 1)
    check("canonical_integrity", ledgerA.integrityOK && ledgerA.foreignKeysOK)
    check("no_duplicate_mapping", ledgerA.duplicateSourceRecords == 0)
    let l2 = checks.allSatisfy(\.passed)

    // L3: the same bytes map the same way every time, and match a named oracle.
    check("reimport_unchanged", repeated.status == .unchanged)
    check(
      "independent_import_identical",
      ledgerA.eventSetHash == ledgerB.eventSetHash
        && ledgerA.reconciliationHash == ledgerB.reconciliationHash
        && ledgerA.eventsByKind == ledgerB.eventsByKind && independent.status == .committed)
    if let oracle {
      check(
        "oracle_counts",
        oracle.eventsByKind == ledgerA.eventsByKind && oracle.transferPairs == ledgerA.transferPairs)
    }
    let l3 = l2 && oracle != nil && checks.allSatisfy(\.passed)

    // L4 (canonical round trip) and L5 (behavioural parity) need evidence this tool cannot
    // produce, so they are never claimed here.
    let level: CompatibilityLevel =
      l3 ? .l3DeterministicMapping : l2 ? .l2LosslessStaging : .l1ReadOnlyClassification

    return MoneyManagerV19ImportCertificate(
      certificateVersion: MoneyManagerV19ImportCertificate.version,
      sourceSHA256: before.sha256, sourceByteCount: before.count,
      container: review.container.rawValue, profileID: review.profileID ?? "",
      adapterVersion: MoneyManagerV19Adapter.version, locale: locale,
      sourceTimeZone: sourceTimeZone.certificateLabel, oracleID: oracle?.oracleID,
      achievedLevel: level,
      tableCount: review.tableCount ?? 0, recordCount: review.recordCount ?? 0,
      fieldCount: review.fieldCount ?? 0, mappedCount: mapped, preservedCount: preserved,
      excludedCount: excluded, eventCount: ledgerA.eventCount, eventsByKind: ledgerA.eventsByKind,
      transferPairs: ledgerA.transferPairs, eventSetHash: ledgerA.eventSetHash,
      reconciliationHash: ledgerA.reconciliationHash, checks: checks)
  }

  private static func sourceDigest(_ url: URL) throws -> (sha256: String, count: Int) {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
      throw MoneyManagerV19ImportCertifierError.unreadableSource
    }
    return (CanonicalReceiptDigest.sha256(data), data.count)
  }
}

extension SourceTimeZone {
  fileprivate var certificateLabel: String {
    if let identifier = ianaIdentifier { return "iana:\(identifier)" }
    return "fixed:\(fixedOffsetSeconds ?? 0)"
  }
}

/// Read-only aggregates of a committed canonical ledger.
private struct CanonicalAggregates {
  let eventCount: Int
  let eventsByKind: [String: Int]
  let transferPairs: Int
  let eventSetHash: String
  let reconciliationHash: String
  let duplicateSourceRecords: Int
  let integrityOK: Bool
  let foreignKeysOK: Bool

  init(_ url: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let database
    else {
      if database != nil { sqlite3_close(database) }
      throw MoneyManagerV19ImportCertifierError.unreadableCanonical
    }
    defer { sqlite3_close(database) }
    func rows(_ sql: String) throws -> [[String]] {
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement
      else { throw MoneyManagerV19ImportCertifierError.unreadableCanonical }
      defer { sqlite3_finalize(statement) }
      var result: [[String]] = []
      while true {
        let rc = sqlite3_step(statement)
        if rc == SQLITE_DONE { break }
        guard rc == SQLITE_ROW else { throw MoneyManagerV19ImportCertifierError.unreadableCanonical }
        result.append(
          (0..<sqlite3_column_count(statement)).map { column in
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
          })
      }
      return result
    }
    func int(_ sql: String) throws -> Int { Int(try rows(sql).first?.first ?? "") ?? -1 }

    eventCount = try int("SELECT count(*) FROM economic_event")
    eventsByKind = Dictionary(
      uniqueKeysWithValues: try rows(
        "SELECT event_kind, count(*) FROM economic_event GROUP BY event_kind"
      ).map { ($0[0], Int($0[1]) ?? -1) })
    transferPairs = try int("SELECT count(*) FROM economic_event_transfer")
    let receipts = try rows("SELECT event_set_hash, reconciliation_hash FROM import_receipt")
    guard receipts.count == 1 else { throw MoneyManagerV19ImportCertifierError.unreadableCanonical }
    eventSetHash = receipts[0][0]
    reconciliationHash = receipts[0][1]
    duplicateSourceRecords = try int(
      "SELECT count(*) FROM (SELECT source_record_id FROM economic_event GROUP BY source_record_id HAVING count(*) > 1)"
    )
    integrityOK = try rows("PRAGMA integrity_check").map { $0.first ?? "" } == ["ok"]
    foreignKeysOK = try rows("PRAGMA foreign_key_check").isEmpty
  }
}
