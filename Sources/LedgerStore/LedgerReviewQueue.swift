import Foundation
import LedgerCore

/// To Review (#238): entries the app added for the person (recurring dates, installment
/// payments, workbook rows, merged entries) wait here until they have looked at them.
///
/// This is app state, not ledger data: it lives in a sidecar beside the ledger in app storage
/// (`<ledger>.to-review.json`), so marking an entry reviewed never writes to the ledger.
/// Each entry is held with the revision it had when it arrived. Once that revision is no
/// longer current (the entry was edited) or the entry is closed or gone, it no longer waits.
public struct LedgerReviewQueue: Equatable, Sendable {
  /// Transaction ID → the revision ID it had when it was added.
  public private(set) var revisionByTransaction: [String: String]

  public init(revisionByTransaction: [String: String] = [:]) {
    self.revisionByTransaction = revisionByTransaction
  }

  public var isEmpty: Bool { revisionByTransaction.isEmpty }

  /// The entries in `after` that are active and were not in `before`: what an action added.
  public static func added(
    since before: Set<String>, in after: [LedgerTransactionSnapshot]
  ) -> [LedgerTransactionSnapshot] {
    after.filter { !before.contains($0.id) && $0.currentRevision.lifecycle == .active }
  }

  /// Puts these entries in the queue at their current revision.
  public mutating func add(_ transactions: some Sequence<LedgerTransactionSnapshot>) {
    for transaction in transactions {
      revisionByTransaction[transaction.id] = transaction.currentRevision.id
    }
  }

  public mutating func markReviewed(_ transactionIDs: some Sequence<String>) {
    for id in transactionIDs { revisionByTransaction[id] = nil }
  }

  public mutating func markAllReviewed() {
    revisionByTransaction = [:]
  }

  /// The IDs of the entries still waiting: active, and unchanged since they were added.
  public func waitingIDs(in transactions: [LedgerTransactionSnapshot]) -> Set<String> {
    guard !revisionByTransaction.isEmpty else { return [] }
    var waiting = Set<String>()
    for transaction in transactions
    where transaction.currentRevision.lifecycle == .active
      && revisionByTransaction[transaction.id] == transaction.currentRevision.id
    {
      waiting.insert(transaction.id)
    }
    return waiting
  }

  /// Forgets entries that no longer wait, so the sidecar doesn't grow with edited or closed
  /// entries.
  public mutating func prune(keeping waiting: Set<String>) {
    revisionByTransaction = revisionByTransaction.filter { waiting.contains($0.key) }
  }

  // MARK: Sidecar file

  public static let sidecarSuffix = ".to-review.json"
  /// Room for well over 50,000 waiting entries.
  public static let maximumSidecarBytes = 16 * 1_024 * 1_024
  static let currentFormatVersion = 1

  public static func sidecarURL(forLedgerAt ledgerURL: URL) -> URL {
    URL(fileURLWithPath: ledgerURL.path + sidecarSuffix)
  }

  private struct File: Codable {
    var formatVersion: Int
    /// Sorted by transaction ID, so the same queue always writes the same bytes.
    var entries: [Entry]
    struct Entry: Codable {
      var transactionID: String
      var revisionID: String
    }
  }

  /// The queue saved beside `ledgerURL`; empty when there is none, it can't be read, or it was
  /// written by a newer app. A symlink, a folder or an oversized file is never read.
  public static func read(besideLedgerAt ledgerURL: URL) -> LedgerReviewQueue {
    guard
      let data = try? LedgerPrivateFile.read(
        at: sidecarURL(forLedgerAt: ledgerURL), maximumSize: maximumSidecarBytes),
      let file = try? JSONDecoder().decode(File.self, from: data),
      file.formatVersion == currentFormatVersion
    else { return LedgerReviewQueue() }
    var revisions: [String: String] = [:]
    for entry in file.entries { revisions[entry.transactionID] = entry.revisionID }
    return LedgerReviewQueue(revisionByTransaction: revisions)
  }

  /// Saves owner-only and replaces the old file in one step. An empty queue removes the file.
  public func write(besideLedgerAt ledgerURL: URL) throws {
    let url = Self.sidecarURL(forLedgerAt: ledgerURL)
    guard !isEmpty else {
      try LedgerPrivateFile.write(nil, at: url, maximumSize: Self.maximumSidecarBytes)
      return
    }
    let file = File(
      formatVersion: Self.currentFormatVersion,
      entries: revisionByTransaction.keys.sorted().map {
        File.Entry(transactionID: $0, revisionID: revisionByTransaction[$0]!)
      })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try LedgerPrivateFile.write(
      try encoder.encode(file), at: url, maximumSize: Self.maximumSidecarBytes)
  }

  public static func removeSidecar(besideLedgerAt ledgerURL: URL) {
    try? LedgerPrivateFile.write(
      nil, at: sidecarURL(forLedgerAt: ledgerURL), maximumSize: maximumSidecarBytes)
  }
}
