import CryptoKit
import Foundation
import ImageIO
import Vision

public struct ReceiptAttachment: Equatable, Identifiable, Sendable {
  public let id: String
  public let filename: String
  public let byteCount: Int
  public let sha256: String

  public init(id: String, filename: String, byteCount: Int, sha256: String) {
    self.id = id
    self.filename = filename
    self.byteCount = byteCount
    self.sha256 = sha256
  }
}

public struct ReceiptOCRLine: Equatable, Sendable {
  public let text: String
  public let confidence: Float

  public init(text: String, confidence: Float) {
    self.text = text
    self.confidence = confidence
  }
}

public struct ReceiptOCRDraft: Equatable, Sendable {
  public let attachmentID: String
  public let lines: [ReceiptOCRLine]
  public let confirmed: Bool

  public init(attachmentID: String, lines: [ReceiptOCRLine], confirmed: Bool = false) {
    self.attachmentID = attachmentID
    self.lines = lines
    self.confirmed = confirmed
  }

  /// Confirmation is deliberately a separate value. It never writes ledger truth.
  public func confirm() throws -> ReceiptOCRDraft {
    guard !attachmentID.isEmpty else { throw ReceiptAttachmentError.invalidAttachment }
    return .init(attachmentID: attachmentID, lines: lines, confirmed: true)
  }
}

public enum ReceiptAttachmentError: Error, Equatable, Sendable {
  case invalidRoot
  case invalidSource
  case sourceIsNotRegularFile
  case sourceIsTooLarge
  case unreadableSource
  case unsupportedImage
  case invalidAttachment
  case ocrFailed
}

/// Stores receipt bytes privately and runs OCR locally. It does not touch SQLite or create
/// financial revisions; callers must explicitly map any reviewed suggestion to a ledger command.
public actor ReceiptAttachmentStore {
  public static let defaultMaximumBytes = 25_000_000

  private let rootURL: URL
  private let maximumBytes: Int

  public init(rootURL: URL, maximumBytes: Int = ReceiptAttachmentStore.defaultMaximumBytes) throws {
    guard rootURL.isFileURL, maximumBytes > 0 else { throw ReceiptAttachmentError.invalidRoot }
    self.rootURL = rootURL.standardizedFileURL
    self.maximumBytes = maximumBytes
    do {
      try FileManager.default.createDirectory(
        at: self.rootURL, withIntermediateDirectories: true)
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: self.rootURL.path)
    } catch {
      throw ReceiptAttachmentError.invalidRoot
    }
  }

  public func importFile(from sourceURL: URL) throws -> ReceiptAttachment {
    guard sourceURL.isFileURL else { throw ReceiptAttachmentError.invalidSource }
    let values: URLResourceValues
    do {
      values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    } catch {
      throw ReceiptAttachmentError.unreadableSource
    }
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw ReceiptAttachmentError.sourceIsNotRegularFile
    }
    guard let size = values.fileSize, size >= 0, size <= maximumBytes else {
      throw ReceiptAttachmentError.sourceIsTooLarge
    }
    let data: Data
    do {
      data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
    } catch {
      throw ReceiptAttachmentError.unreadableSource
    }
    guard data.count <= maximumBytes else { throw ReceiptAttachmentError.sourceIsTooLarge }
    let digest = Self.sha256(data)
    let filename = Self.safeFilename(sourceURL.lastPathComponent)
    let destination = rootURL.appendingPathComponent("\(digest)-\(filename)", isDirectory: false)
    if FileManager.default.fileExists(atPath: destination.path) {
      return .init(id: digest, filename: filename, byteCount: data.count, sha256: digest)
    }
    let temporary = rootURL.appendingPathComponent(".incoming-\(UUID().uuidString)", isDirectory: false)
    do {
      try data.write(to: temporary, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: temporary.path)
      do {
        try FileManager.default.moveItem(at: temporary, to: destination)
      } catch CocoaError.fileWriteFileExists {
        try? FileManager.default.removeItem(at: temporary)
      }
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw ReceiptAttachmentError.unreadableSource
    }
    return .init(id: digest, filename: filename, byteCount: data.count, sha256: digest)
  }

  public func remove(_ attachment: ReceiptAttachment) throws {
    guard Self.isDigest(attachment.id), attachment.sha256 == attachment.id else {
      throw ReceiptAttachmentError.invalidAttachment
    }
    let destination = rootURL.appendingPathComponent(
      "\(attachment.id)-\(Self.safeFilename(attachment.filename))", isDirectory: false)
    do {
      try FileManager.default.removeItem(at: destination)
    } catch CocoaError.fileNoSuchFile {
      return
    } catch {
      throw ReceiptAttachmentError.invalidAttachment
    }
  }

  public func suggestions(for attachment: ReceiptAttachment) throws -> ReceiptOCRDraft {
    guard Self.isDigest(attachment.id), attachment.sha256 == attachment.id else {
      throw ReceiptAttachmentError.invalidAttachment
    }
    let url = rootURL.appendingPathComponent(
      "\(attachment.id)-\(Self.safeFilename(attachment.filename))", isDirectory: false)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw ReceiptAttachmentError.invalidAttachment
    }
    guard CGImageSourceCreateWithURL(url as CFURL, nil) != nil else {
      throw ReceiptAttachmentError.unsupportedImage
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["en-US"]
    do {
      try VNImageRequestHandler(url: url, options: [:]).perform([request])
    } catch {
      throw ReceiptAttachmentError.ocrFailed
    }
    let lines = (request.results ?? []).prefix(256).compactMap { observation -> ReceiptOCRLine? in
      guard let candidate = observation.topCandidates(1).first else { return nil }
      let text = String(candidate.string.prefix(4_096))
      guard !text.isEmpty, candidate.confidence.isFinite else { return nil }
      return .init(text: text, confidence: candidate.confidence)
    }
    return .init(attachmentID: attachment.id, lines: Array(lines))
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func isDigest(_ value: String) -> Bool {
    value.count == 64 && value.unicodeScalars.allSatisfy {
      ("0"..."9").contains($0) || ("a"..."f").contains($0)
    }
  }

  private static func safeFilename(_ value: String) -> String {
    let allowed = value.unicodeScalars.map { scalar -> Character in
      switch scalar.value {
      case 48...57, 65...90, 97...122, 45, 46, 95: Character(String(scalar))
      default: "_"
      }
    }
    let result = String(allowed.prefix(96))
    return result.isEmpty || result == "." || result == ".." ? "receipt" : result
  }
}
