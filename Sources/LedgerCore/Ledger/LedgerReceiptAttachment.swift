import CryptoKit
import Foundation

/// A receipt image or PDF kept inside the ledger. This is the metadata; the bytes are read
/// separately so listing receipts never loads the images.
public struct LedgerReceiptAttachment: Equatable, Sendable {
  public enum MediaType: String, CaseIterable, Sendable {
    case jpeg = "image/jpeg"
    case png = "image/png"
    case heic = "image/heic"
    case pdf = "application/pdf"

    /// What the bytes are, from their signature, or nil for anything else. The caller's file
    /// name or declared type is never trusted.
    public init?(sniffing data: Data) {
      let bytes = [UInt8](data.prefix(16))
      func starts(_ prefix: [UInt8]) -> Bool { bytes.starts(with: prefix) }
      if starts([0xFF, 0xD8, 0xFF]) {
        self = .jpeg
      } else if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
        self = .png
      } else if starts(Array("%PDF-".utf8)) {
        self = .pdf
      } else if bytes.count >= 12, Array(bytes[4..<8]) == Array("ftyp".utf8),
        let brand = String(bytes: bytes[8..<12], encoding: .ascii),
        ["heic", "heix", "heim", "heis", "mif1", "msf1"].contains(brand)
      {
        self = .heic
      } else {
        return nil
      }
    }
  }

  /// Largest single receipt, and the most all receipts in one ledger may take together. The
  /// receipt budget is separate from the import payload budget, so receipts never push an
  /// import over its limit.
  public static let maximumBytes = 25 * 1_024 * 1_024
  public static let maximumTotalBytes = 1_024 * 1_024 * 1_024

  public let id: String
  /// The ledger transaction, imported event or imported transfer it belongs to; nil while
  /// unresolved.
  public let transactionID: String?
  public let sha256: String
  public let byteCount: Int
  public let mediaType: MediaType
  public let origin: LedgerOrigin
  public let createdAt: UTCInstant
  public let lifecycle: LedgerLifecycleState

  public init(
    id: String, transactionID: String?, sha256: String, byteCount: Int, mediaType: MediaType,
    origin: LedgerOrigin, createdAt: UTCInstant, lifecycle: LedgerLifecycleState = .active
  ) throws {
    guard CanonicalIdentifier.isValid(id), CanonicalIdentifier.isValid(sha256),
      transactionID.map(CanonicalIdentifier.isValid) ?? true,
      (1...Self.maximumBytes).contains(byteCount)
    else { throw LedgerDomainError.invalidReference }
    self.id = id
    self.transactionID = transactionID
    self.sha256 = sha256
    self.byteCount = byteCount
    self.mediaType = mediaType
    self.origin = origin
    self.createdAt = createdAt
    self.lifecycle = lifecycle
  }

  /// The same image added from the same origin is the same receipt.
  public static func id(origin: LedgerOrigin, sha256: String) -> String {
    let text = ["ledger-atlas/receipt-attachment/v1", origin.id, sha256]
      .map { "\($0.utf8.count):\($0)" }.joined()
    return digest(Data(text.utf8))
  }

  public static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
