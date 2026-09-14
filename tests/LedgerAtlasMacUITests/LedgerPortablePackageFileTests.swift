import CryptoKit
import Foundation
import LedgerCore
import LedgerAtlasMacUI
import LedgerStore
import Testing

@Test func portablePackageFileRoundTripsAndRejectsPayloadTampering() throws {
  let payload = Data("synthetic-ledger-package".utf8)
  let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
  let manifest = LedgerExportManifest(
    formatVersion: LedgerPortablePackageFormat.version,
    formatFingerprint: LedgerPortablePackageFormat.fingerprint,
    payloadSHA256: digest, createdAtMilliseconds: 0)
  let encoded = try LedgerPortablePackageFile.encode(manifest: manifest, payload: payload)
  let decoded = try LedgerPortablePackageFile.decode(encoded)
  #expect(decoded.manifest == manifest)
  #expect(decoded.payload == payload)

  var object = try #require(
    JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  object["payload"] = Data("tampered".utf8).base64EncodedString()
  let tampered = try JSONSerialization.data(withJSONObject: object)
  #expect(throws: LedgerPortablePackageFile.Error.invalidEnvelope) {
    _ = try LedgerPortablePackageFile.decode(tampered)
  }
}

@MainActor
@Test func failedPortablePackageImportRemovesItsNewDestination() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let payload = Data("not a canonical package".utf8)
  let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
  let manifest = LedgerExportManifest(
    formatVersion: LedgerPortablePackageFormat.version,
    formatFingerprint: LedgerPortablePackageFormat.fingerprint,
    payloadSHA256: digest, createdAtMilliseconds: 0)
  let packageURL = directory.appendingPathComponent("invalid.ledgerpackage")
  try LedgerPortablePackageFile.encode(manifest: manifest, payload: payload).write(to: packageURL)
  #expect(chmod(packageURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0)

  let destination = directory.appendingPathComponent("should-not-remain.sqlite")
  let journey = LedgerJourney()
  #expect(throws: LedgerApplication.Error.invalidCommand) {
    try journey.restorePortablePackage(from: packageURL, to: destination)
  }
  #expect(!FileManager.default.fileExists(atPath: destination.path))
}
