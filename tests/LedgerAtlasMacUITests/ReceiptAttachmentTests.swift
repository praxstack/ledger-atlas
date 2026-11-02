import Foundation
import LedgerCore
import LedgerStore
import Testing

@testable import LedgerAtlasMacUI

// Synthetic data only: the "images" are tiny made-up byte strings with real file signatures,
// and every amount and name is made up.

private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array("synthetic-png".utf8))
private let pdf = Data("%PDF-1.7 synthetic".utf8)

@MainActor
private func editableLedger(at url: URL) async throws -> LedgerJourney {
  let suite = "LedgerAtlasMacUITests.receipts.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let bookmarks = SecurityScopedBookmarkStore(
    defaults: defaults, makeBookmark: { Data($0.path.utf8) },
    resolveBookmark: { URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)) })
  let journey = LedgerJourney()
  let created = await LedgerAtlasRootView.performLedgerLifecycle(
    .create, at: url, bookmarkStore: bookmarks, widgetPublisher: .init(write: { _ in }),
    journey: journey, session: LedgerSession(testingScopeStarter: { _ in true }),
    scopeStarter: { _ in true }, scopeStopper: { _ in })
  #expect(created.kind == .created)
  try journey.performBeginEditing()
  return journey
}

private func withDirectory(_ body: (URL) async throws -> Void) async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try await body(directory)
}

@Test func receiptFilesReadOnlyRegularFilesWithinTheLimit() async throws {
  try await withDirectory { directory in
    let image = directory.appendingPathComponent("receipt.png")
    try png.write(to: image)
    #expect(try ReceiptFiles.read(image) == png)

    let link = directory.appendingPathComponent("link.png")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: image)
    #expect(throws: ReceiptAttachmentError.sourceIsNotRegularFile) { try ReceiptFiles.read(link) }
    #expect(throws: ReceiptAttachmentError.sourceIsNotRegularFile) {
      try ReceiptFiles.read(directory)
    }

    let empty = directory.appendingPathComponent("empty.png")
    try Data().write(to: empty)
    #expect(throws: ReceiptAttachmentError.unsupportedImage) { try ReceiptFiles.read(empty) }

    let oversized = directory.appendingPathComponent("oversized.png")
    #expect(FileManager.default.createFile(atPath: oversized.path, contents: nil))
    let handle = try FileHandle(forWritingTo: oversized)
    try handle.truncate(atOffset: UInt64(LedgerReceiptAttachment.maximumBytes + 1))
    try handle.close()
    #expect(throws: ReceiptAttachmentError.sourceIsTooLarge) { try ReceiptFiles.read(oversized) }
  }
}

@Test func textRecognitionRefusesPDFsAndUndecodableBytes() {
  let id = String(repeating: "a", count: 64)
  #expect(throws: ReceiptAttachmentError.unsupportedImage) {
    try ReceiptFiles.suggestions(for: pdf, attachmentID: id)
  }
  // A real PNG signature with no image inside.
  #expect(throws: ReceiptAttachmentError.unsupportedImage) {
    try ReceiptFiles.suggestions(for: png, attachmentID: id)
  }
}

@Test func amountSuggestionsAreLargestFirstAndNeverWriteAnything() {
  let draft = ReceiptOCRDraft(
    attachmentID: String(repeating: "a", count: 64),
    lines: [
      .init(text: "Tea 40.00", confidence: 0.9),
      .init(text: "Snacks 1,20,000.50", confidence: 0.8),
      .init(text: "Total 120.5 incl tax", confidence: 0.95),
      .init(text: "Tea again 40.00, table 12", confidence: 0.7),
      .init(text: "Phone 98765 43210", confidence: 0.6),
    ])
  #expect(draft.amountCandidates == ["120000.50", "120.5", "40.00"])
  #expect(ReceiptOCRDraft(attachmentID: "x", lines: []).amountCandidates.isEmpty)
}

@MainActor
@Test func receiptsLiveInTheLedgerAndOnlyAConfirmedFormRecordsAnExpense() async throws {
  try await withDirectory { directory in
    let journey = try await editableLedger(at: directory.appendingPathComponent("ledger.sqlite"))
    let origin = try LedgerOrigin.macNative()
    let wallet = try LedgerAccount(
      id: try StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
      name: "Wallet", currencyUnit: "INR", origin: origin)
    try journey.createAccount(wallet)
    let image = directory.appendingPathComponent("picked.png")
    try png.write(to: image)
    let now = UTCInstant(epochMilliseconds: 1_790_000_000_000)

    // Adding a receipt changes no transactions; it waits unlinked.
    let before = try #require(journey.snapshot).transactions.count
    let receipt = try journey.addReceipt(from: image, createdAt: now)
    #expect(try journey.addReceipt(from: image, createdAt: now) == receipt)
    #expect(try journey.receiptAttachments() == [receipt])
    #expect(receipt.transactionID == nil)
    #expect(try journey.receiptBytes(receipt.id) == png)
    #expect(journey.snapshot?.transactions.count == before)
    // The ledger holds its own copy: the picked file can go away.
    try FileManager.default.removeItem(at: image)
    #expect(try journey.receiptBytes(receipt.id) == png)

    // Confirming the form records one expense and links the receipt, once.
    let submission = UUID().uuidString
    let expense = try journey.createExpense(
      fromReceipt: receipt.id, amountLiteral: " 120.50 ", accountID: wallet.id,
      categoryID: nil, createdAt: now, submissionID: submission)
    let again = try journey.createExpense(
      fromReceipt: receipt.id, amountLiteral: "120.50", accountID: wallet.id,
      categoryID: nil, createdAt: now, submissionID: submission)
    #expect(again.transactionID == expense.transactionID)
    #expect(journey.snapshot?.transactions.count == before + 1)
    #expect(try journey.receiptAttachments().first?.transactionID == expense.transactionID)

    // Unlink, then remove: a removed receipt can't record anything.
    try journey.linkReceipt(receipt.id, to: nil)
    #expect(try journey.receiptAttachments().first?.transactionID == nil)
    try journey.removeReceipt(receipt.id)
    #expect(try journey.receiptAttachments().first?.lifecycle == .tombstoned)
    #expect(throws: (any Error).self) {
      try journey.createExpense(
        fromReceipt: receipt.id, amountLiteral: "5", accountID: wallet.id, categoryID: nil,
        createdAt: now, submissionID: UUID().uuidString)
    }
    #expect(journey.snapshot?.transactions.count == before + 1)
  }
}

@MainActor
@Test func receiptsNeedAnEditableLedger() async throws {
  try await withDirectory { directory in
    let image = directory.appendingPathComponent("picked.png")
    try png.write(to: image)
    let journey = LedgerJourney()
    #expect(throws: LedgerApplication.Error.invalidCommand) {
      try journey.addReceipt(from: image, createdAt: UTCInstant(epochMilliseconds: 0))
    }
    #expect(throws: LedgerApplication.Error.invalidCommand) { try journey.receiptAttachments() }
  }
}
