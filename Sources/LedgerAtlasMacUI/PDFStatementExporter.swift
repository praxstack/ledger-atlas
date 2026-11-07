import AppKit
import CoreGraphics
import Foundation
import LedgerCore
import LedgerStore

/// A statement with one section per currency. Amounts in different currencies are never
/// added together, because the ledger has no exchange rate to do it honestly.
public struct LedgerStatement: Equatable, Sendable {
  public let reports: [LedgerReport]

  public init(reports: [LedgerReport]) {
    self.reports = reports
  }

  /// One report for every currency that counts toward totals, in currency-code order.
  public init(snapshot: LedgerStore.LedgerReadSnapshot) throws {
    self.reports = try Self.unitCodes(in: snapshot).map {
      try LedgerApplication.report(from: snapshot, unitCode: $0)
    }
  }

  /// Currencies of open, visible accounts that count toward totals, plus any other currency
  /// their transactions use. Falls back to a single currency so an empty ledger still shows
  /// its record counts.
  public static func unitCodes(in snapshot: LedgerStore.LedgerReadSnapshot) -> [String] {
    let counted = snapshot.accounts.filter {
      $0.lifecycle == .active && !$0.hidden && $0.includeInTotals
    }
    let countedIDs = Set(counted.map(\.id))
    var units = Set(counted.map(\.currencyUnit))
    for transaction in snapshot.transactions where transaction.currentRevision.lifecycle == .active {
      for effect in transaction.currentRevision.draft.effects where countedIDs.contains(effect.accountID) {
        units.insert(effect.amount.unitCode)
      }
    }
    if units.isEmpty {
      return [snapshot.accounts.first?.currencyUnit ?? "USD"]
    }
    return units.sorted()
  }

  /// Plain text for screen readers, the Statistics screen and the PDF.
  public var text: String {
    guard let first = reports.first else { return "" }
    guard reports.count > 1 else { return first.accessibleTable }
    let codes = reports.map(\.unitCode).joined(separator: ", ")
    var lines = [
      first.title,
      "Shown separately by currency: \(codes). Amounts in different currencies are never added together.",
    ]
    for report in reports {
      lines += ["", "\(report.unitCode)"] + report.currencyLines
    }
    if !first.inventoryLines.isEmpty {
      lines += [""] + first.inventoryLines
    }
    return lines.joined(separator: "\n")
  }
}

public enum LedgerPDFStatementExporter {
  public enum Error: Swift.Error, Equatable, Sendable {
    case invalidDestination
    case writeFailed
  }

  public static func export(_ report: LedgerReport, to url: URL) throws {
    try export(LedgerStatement(reports: [report]), to: url)
  }

  public static func export(_ statement: LedgerStatement, to url: URL) throws {
    try export(
      lines: statement.text.split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init), to: url)
  }

  /// Writes `lines` as a plain, paginated PDF. The PDF is output only: nothing reads it back.
  public static func export(lines: [String], to url: URL) throws {
    let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    guard url.isFileURL, !url.path.isEmpty, !isDirectory else { throw Error.invalidDestination }
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data),
      let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
    else { throw Error.writeFailed }
    let pageSize = CGSize(width: 612, height: 792)
    let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    let lineHeight = font.ascender - font.descender + 4
    let linesPerPage = max(1, Int((pageSize.height - 72) / lineHeight))
    // Pages are cut by line count, so no line may wrap when drawn: a wrapped line would push
    // the page past its rectangle and the overflow would be clipped. Each line is broken to
    // the columns the monospaced font fits across the page, one column spare.
    let advance = max(1, ("M" as NSString).size(withAttributes: attributes).width)
    let columns = max(20, Int((pageSize.width - 72) / advance) - 1)
    let drawn = wrapped(lines, columns: columns)
    for pageLines in stride(from: 0, to: max(drawn.count, 1), by: linesPerPage).map({ index in
      Array(drawn[index..<min(index + linesPerPage, drawn.count)])
    }) {
      context.beginPDFPage(nil)
      let graphics = NSGraphicsContext(cgContext: context, flipped: true)
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = graphics
      let text = pageLines.joined(separator: "\n")
      NSAttributedString(string: text, attributes: attributes).draw(
        in: CGRect(x: 36, y: 36, width: pageSize.width - 72, height: pageSize.height - 72))
      NSGraphicsContext.restoreGraphicsState()
      context.endPDFPage()
    }
    context.closePDF()
    do {
      // The save panel has already asked before replacing an existing file.
      try SavedFile.write(data as Data, to: url, replacing: true)
    } catch SavedFile.Error.notAFile {
      throw Error.invalidDestination
    } catch {
      throw Error.writeFailed
    }
  }

  /// `lines` broken so none is longer than `columns` characters. A line breaks at its last
  /// space that fits, or mid-word when a word alone is too long; the continuation keeps the
  /// line's leading indent plus two spaces so it reads as the same entry.
  package static func wrapped(_ lines: [String], columns: Int) -> [String] {
    let columns = max(columns, 8)
    var result: [String] = []
    for line in lines {
      guard line.count > columns else {
        result.append(line)
        continue
      }
      let indent = String(line.prefix { $0 == " " }.prefix(columns / 2))
      let continuation = indent + "  "
      var remaining = Substring(line)
      var prefix = ""
      while prefix.count + remaining.count > columns {
        let room = columns - prefix.count
        let head = remaining.prefix(room + 1)
        var cut = head.lastIndex(of: " ").flatMap { $0 > remaining.startIndex ? $0 : nil }
        if let space = cut, remaining[remaining.startIndex..<space].allSatisfy({ $0 == " " }) {
          cut = nil
        }
        let end = cut ?? remaining.index(remaining.startIndex, offsetBy: room)
        result.append(prefix + String(remaining[remaining.startIndex..<end]))
        remaining = remaining[end...].drop { $0 == " " }
        prefix = continuation
      }
      if !remaining.isEmpty { result.append(prefix + String(remaining)) }
    }
    return result
  }
}
