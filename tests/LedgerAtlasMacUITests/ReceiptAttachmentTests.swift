import CryptoKit
import Foundation
import Testing

@testable import LedgerAtlasMacUI

@Test func receiptAttachmentStoreHashesDeduplicatesAndBoundsPrivateFiles() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let root = directory.appendingPathComponent("private-receipts")
  let source = directory.appendingPathComponent("receipt?.txt")
  let bytes = Data("synthetic receipt bytes".utf8)
  try bytes.write(to: source)
  let store = try ReceiptAttachmentStore(rootURL: root, maximumBytes: 1024)

  let first = try await store.importFile(from: source)
  let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  #expect(first.id == expected)
  #expect(first.sha256 == expected)
  #expect(first.filename == "receipt_.txt")
  #expect(first.byteCount == bytes.count)
  #expect(try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber == 0o700)

  let second = try await store.importFile(from: source)
  #expect(second == first)
  let stored = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
  #expect(stored.count == 1)
  #expect(try FileManager.default.attributesOfItem(atPath: stored[0].path)[.posixPermissions] as? NSNumber == 0o600)
  #expect(await receiptError { _ = try await store.suggestions(for: first) } != nil)
  try await store.remove(first)
  #expect(!FileManager.default.fileExists(atPath: stored[0].path))
}

@Test func receiptAttachmentStoreRejectsOversizedAndSymlinkSources() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = try ReceiptAttachmentStore(
    rootURL: directory.appendingPathComponent("receipts"), maximumBytes: 3)
  let oversized = directory.appendingPathComponent("oversized.bin")
  try Data("1234".utf8).write(to: oversized)
  #expect(await receiptError { _ = try await store.importFile(from: oversized) } == .sourceIsTooLarge)
  let target = directory.appendingPathComponent("target.bin")
  try Data("ok".utf8).write(to: target)
  let link = directory.appendingPathComponent("link.bin")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
  #expect(await receiptError { _ = try await store.importFile(from: link) } == .sourceIsNotRegularFile)
}

private func receiptError(
  _ operation: () async throws -> Void
) async -> ReceiptAttachmentError? {
  do {
    try await operation()
    return nil
  } catch let error as ReceiptAttachmentError {
    return error
  } catch {
    return nil
  }
}
