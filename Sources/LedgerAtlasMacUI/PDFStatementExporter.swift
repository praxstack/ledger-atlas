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
    let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    guard url.isFileURL, !url.path.isEmpty, !isDirectory else { throw Error.invalidDestination }
    let lines = statement.text.split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
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
    for pageLines in stride(from: 0, to: max(lines.count, 1), by: linesPerPage).map({ index in
      Array(lines[index..<min(index + linesPerPage, lines.count)])
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
      try data.write(to: url, options: .atomic)
    } catch {
      throw Error.writeFailed
    }
  }
}
