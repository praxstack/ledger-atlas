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

  /// Writes `data` to a new owner-only file at `destination` and nothing else.
  ///
  /// The App Sandbox lets the app create only the file the person picked, not a temporary
  /// file beside it, so this creates `destination` exclusively and writes it in place. If any
  /// step fails, the partial file this call created is removed.
  public static func publish(_ data: Data, to destination: URL) throws {
    guard destination.isFileURL else { throw Error.writeFailed }
    let descriptor = open(
      destination.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      mode_t(S_IRUSR | S_IWUSR))
    guard descriptor >= 0 else {
      throw errno == EEXIST ? Error.destinationExists : Error.writeFailed
    }
    var created = stat()
    let wroteAll: Bool = {
      guard fstat(descriptor, &created) == 0, fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0
      else { return false }
      var offset = 0
      let complete = data.withUnsafeBytes { buffer -> Bool in
        while offset < buffer.count {
          let written = write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
          guard written > 0 else { return false }
          offset += written
        }
        return true
      }
      return complete && fsync(descriptor) == 0
    }()
    close(descriptor)
    guard wroteAll else {
      // Remove only the file this call created, never one that replaced it meanwhile.
      var atPath = stat()
      if lstat(destination.path, &atPath) == 0, atPath.st_dev == created.st_dev,
        atPath.st_ino == created.st_ino
      {
        unlink(destination.path)
      }
      throw Error.writeFailed
    }
  }
}
