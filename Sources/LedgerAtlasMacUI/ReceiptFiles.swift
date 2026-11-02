import Darwin
import Foundation
import ImageIO
import LedgerCore
import Vision

public struct ReceiptOCRLine: Equatable, Sendable {
  public let text: String
  public let confidence: Float

  public init(text: String, confidence: Float) {
    self.text = text
    self.confidence = confidence
  }
}

/// Text read from a receipt on this Mac. It is a suggestion only: nothing here writes to the
/// ledger. The person turns a suggestion into a transaction by confirming the expense form.
public struct ReceiptOCRDraft: Equatable, Sendable {
  public let attachmentID: String
  public let lines: [ReceiptOCRLine]

  public init(attachmentID: String, lines: [ReceiptOCRLine]) {
    self.attachmentID = attachmentID
    self.lines = lines
  }

  /// Amounts that appear in the text, largest first, so the total is usually the first one.
  /// Digit-group commas are dropped ("1,20,000.50" → "120000.50").
  public var amountCandidates: [String] {
    var seen = Set<String>()
    var found: [(literal: String, value: Decimal)] = []
    for line in lines {
      for match in line.text.matches(of: #/\d[\d,]*\.\d{1,2}(?!\d)/#) {
        let literal = String(match.output).replacingOccurrences(of: ",", with: "")
        guard (try? ExactDecimal(literal)) != nil, let value = Decimal(string: literal),
          value > 0, seen.insert(literal).inserted
        else { continue }
        found.append((literal, value))
      }
    }
    return found.sorted { $0.value > $1.value }.prefix(8).map { $0.literal }
  }
}

public enum ReceiptAttachmentError: Error, Equatable, Sendable {
  case sourceIsNotRegularFile
  case sourceIsTooLarge
  case unreadableSource
  case unsupportedImage
  case ocrFailed
  /// Portable packages can't carry receipts yet, so a ledger holding any can't be exported as
  /// a package or merged. A SQLite backup keeps them.
  case receiptsCannotTravelInPackages
  /// The expense was recorded but linking the receipt to it failed. Confirming again with the
  /// same form links it without recording a second expense.
  case expenseRecordedButNotLinked
}

/// Reads picked receipt files and runs text recognition locally. Receipt bytes are kept in the
/// ledger itself (see `LedgerStore.addReceipt`), never in a separate folder.
public enum ReceiptFiles {
  /// Largest image area text recognition will decode, to bound memory on hostile files.
  public static let maximumPixels = 40_000_000

  /// Reads a picked file once, without following a symlink. Only a regular file within the
  /// receipt limit is read, and the limit applies to the bytes actually read. Its type is
  /// decided later from the bytes, never from the name.
  public static func read(_ source: URL) throws -> Data {
    guard source.isFileURL else { throw ReceiptAttachmentError.unreadableSource }
    let descriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else {
      throw errno == ELOOP
        ? ReceiptAttachmentError.sourceIsNotRegularFile : ReceiptAttachmentError.unreadableSource
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var info = Darwin.stat()
    guard fstat(descriptor, &info) == 0 else { throw ReceiptAttachmentError.unreadableSource }
    guard (info.st_mode & S_IFMT) == S_IFREG else {
      throw ReceiptAttachmentError.sourceIsNotRegularFile
    }
    let data: Data
    do {
      data = try handle.read(upToCount: LedgerReceiptAttachment.maximumBytes + 1) ?? Data()
    } catch {
      throw ReceiptAttachmentError.unreadableSource
    }
    guard data.count <= LedgerReceiptAttachment.maximumBytes else {
      throw ReceiptAttachmentError.sourceIsTooLarge
    }
    guard !data.isEmpty else { throw ReceiptAttachmentError.unsupportedImage }
    return data
  }

  /// Recognizes text in a receipt image. PDFs and anything ImageIO cannot decode within the
  /// pixel limit throw `unsupportedImage`.
  public static func suggestions(for data: Data, attachmentID: String) throws -> ReceiptOCRDraft {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) > 0,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0, width <= maximumPixels / height
    else { throw ReceiptAttachmentError.unsupportedImage }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["en-US"]
    do {
      try VNImageRequestHandler(data: data, options: [:]).perform([request])
    } catch {
      throw ReceiptAttachmentError.ocrFailed
    }
    let lines = (request.results ?? []).prefix(256).compactMap { observation -> ReceiptOCRLine? in
      guard let candidate = observation.topCandidates(1).first else { return nil }
      let text = String(candidate.string.prefix(4_096))
      guard !text.isEmpty, candidate.confidence.isFinite else { return nil }
      return .init(text: text, confidence: candidate.confidence)
    }
    return .init(attachmentID: attachmentID, lines: Array(lines))
  }
}
