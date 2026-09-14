import CryptoKit
import Foundation
import LedgerCore

public enum LedgerPortablePackageFile {
  public enum Error: Swift.Error, Equatable, Sendable {
    case invalidSource
    case sourceIsTooLarge
    case invalidEnvelope
    case destinationExists
    case unreadableSource
    case writeFailed
  }

  private static let maximumFileBytes = 100 * 1024 * 1024

  private struct Envelope: Codable {
    let formatVersion: Int
    let formatFingerprint: String
    let payloadSHA256: String
    let createdAtMilliseconds: Int64
    let payload: Data
  }

  public static func encode(
    manifest: LedgerExportManifest, payload: Data
  ) throws -> Data {
    guard payload.count <= maximumFileBytes else { throw Error.sourceIsTooLarge }
    let envelope = Envelope(
      formatVersion: manifest.formatVersion,
      formatFingerprint: manifest.formatFingerprint,
      payloadSHA256: manifest.payloadSHA256,
      createdAtMilliseconds: manifest.createdAtMilliseconds,
      payload: payload)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(envelope)
    guard encoded.count <= maximumFileBytes else { throw Error.sourceIsTooLarge }
    return encoded
  }

  public static func decode(_ data: Data) throws -> (manifest: LedgerExportManifest, payload: Data) {
    guard data.count <= maximumFileBytes else { throw Error.sourceIsTooLarge }
    let envelope: Envelope
    do {
      envelope = try JSONDecoder().decode(Envelope.self, from: data)
    } catch {
      throw Error.invalidEnvelope
    }
    let manifest = LedgerExportManifest(
      formatVersion: envelope.formatVersion,
      formatFingerprint: envelope.formatFingerprint,
      payloadSHA256: envelope.payloadSHA256,
      createdAtMilliseconds: envelope.createdAtMilliseconds)
    let digest = SHA256.hash(data: envelope.payload).map { String(format: "%02x", $0) }.joined()
    guard digest == manifest.payloadSHA256 else { throw Error.invalidEnvelope }
    return (manifest, envelope.payload)
  }
}
