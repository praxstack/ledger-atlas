import Foundation
import LedgerCore
import Testing

@testable import LedgerStore

// #238 To Review. Synthetic data only: every amount and date here is made up.

@Suite("To Review queue")
struct LedgerReviewQueueTests {
  private static let origin = try! LedgerOrigin(id: String(repeating: "7", count: 64), label: "local")
  private static let cash = String(repeating: "a", count: 64)

  /// Entry `n` at `revision`, active or closed.
  private static func entry(
    _ n: Int, revision: Int = 1, lifecycle: LedgerLifecycleState = .active
  ) throws -> LedgerTransactionSnapshot {
    let id = try StableLedgerID.transaction(origin: origin, localKey: String(format: "%064x", n))
    let money = try CurrencyAmount(unitCode: "INR", amount: ExactDecimal("\(n)"))
    let when = try SourceTemporal(
      resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 11, day: 1), hour: 9),
      in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .minute)
    let draft = try LedgerTransactionDraft(
      effects: [try .init(accountID: cash, direction: .decrease, amount: money)], categoryID: nil,
      kind: .expense, occurredAt: when, note: nil, origin: origin)
    let record = try LedgerTransactionRevision(
      id: StableLedgerID.revision(transactionID: id, revision: revision), transactionID: id,
      revision: revision,
      predecessorID: revision > 1
        ? try StableLedgerID.revision(transactionID: id, revision: revision - 1) : nil,
      draft: draft, lifecycle: lifecycle, createdAt: UTCInstant(epochMilliseconds: 0))
    return try LedgerTransactionSnapshot(id: id, currentRevision: record)
  }

  @Test("what an action added is exactly the new active entries")
  func addedIsTheNewActiveEntries() throws {
    let old = try Self.entry(1)
    let new = try Self.entry(2)
    let closed = try Self.entry(3, lifecycle: .tombstoned)
    let added = LedgerReviewQueue.added(since: [old.id], in: [old, new, closed])
    #expect(added.map(\.id) == [new.id])
  }

  @Test("an entry waits until it is marked reviewed, edited or closed")
  func entriesWaitUntilReviewedEditedOrClosed() throws {
    let entries = try (1...4).map { try Self.entry($0) }
    var queue = LedgerReviewQueue()
    queue.add(entries)
    #expect(queue.waitingIDs(in: entries) == Set(entries.map(\.id)))

    queue.markReviewed([entries[0].id])
    let edited = try Self.entry(2, revision: 2)
    let closed = try Self.entry(3, revision: 2, lifecycle: .tombstoned)
    // Entry 4 is gone from the ledger altogether.
    let now = [entries[0], edited, closed]
    #expect(queue.waitingIDs(in: now).isEmpty)
    #expect(queue.waitingIDs(in: entries) == [entries[1].id, entries[2].id, entries[3].id])

    queue.prune(keeping: queue.waitingIDs(in: now))
    #expect(queue.isEmpty)
  }

  @Test("Mark All Reviewed empties the queue")
  func markAllReviewedEmptiesTheQueue() throws {
    var queue = LedgerReviewQueue()
    queue.add(try (1...3).map { try Self.entry($0) })
    queue.markAllReviewed()
    #expect(queue.isEmpty)
  }

  @Test("the queue is saved beside the ledger, read back, and removed when empty")
  func theSidecarRoundTrips() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let ledger = directory.appendingPathComponent("Home.ledgeratlas")
    let sidecar = LedgerReviewQueue.sidecarURL(forLedgerAt: ledger)
    #expect(sidecar.lastPathComponent == "Home.ledgeratlas.to-review.json")
    #expect(LedgerReviewQueue.read(besideLedgerAt: ledger).isEmpty)

    var queue = LedgerReviewQueue()
    queue.add(try (1...3).map { try Self.entry($0) })
    try queue.write(besideLedgerAt: ledger)
    let first = try Data(contentsOf: sidecar)
    #expect(LedgerReviewQueue.read(besideLedgerAt: ledger) == queue)
    let attributes = try FileManager.default.attributesOfItem(atPath: sidecar.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    // The same queue always writes the same bytes.
    try LedgerReviewQueue.read(besideLedgerAt: ledger).write(besideLedgerAt: ledger)
    #expect(try Data(contentsOf: sidecar) == first)

    queue.markAllReviewed()
    try queue.write(besideLedgerAt: ledger)
    #expect(!FileManager.default.fileExists(atPath: sidecar.path))
  }

  @Test("a damaged, newer or linked sidecar reads as an empty queue")
  func anUnreadableSidecarIsEmpty() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let ledger = directory.appendingPathComponent("Home.ledgeratlas")
    let sidecar = LedgerReviewQueue.sidecarURL(forLedgerAt: ledger)

    try Data("not json".utf8).write(to: sidecar)
    #expect(LedgerReviewQueue.read(besideLedgerAt: ledger).isEmpty)

    try Data(#"{"entries":[{"revisionID":"r","transactionID":"t"}],"formatVersion":2}"#.utf8)
      .write(to: sidecar)
    #expect(LedgerReviewQueue.read(besideLedgerAt: ledger).isEmpty)

    try FileManager.default.removeItem(at: sidecar)
    // The same content as a plain file is read, so only the link is refused below.
    let other = directory.appendingPathComponent("Other.ledgeratlas")
    let elsewhere = LedgerReviewQueue.sidecarURL(forLedgerAt: other)
    try Data(#"{"entries":[{"revisionID":"r","transactionID":"t"}],"formatVersion":1}"#.utf8)
      .write(to: elsewhere)
    #expect(
      LedgerReviewQueue.read(besideLedgerAt: other)
        == LedgerReviewQueue(revisionByTransaction: ["t": "r"]))
    try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: elsewhere)
    #expect(LedgerReviewQueue.read(besideLedgerAt: ledger).isEmpty)
  }
}
