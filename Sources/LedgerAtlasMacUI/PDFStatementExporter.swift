import AppKit
import CoreGraphics
import Foundation
import LedgerCore

public enum LedgerPDFStatementExporter {
  public enum Error: Swift.Error, Equatable, Sendable {
    case invalidDestination
    case writeFailed
  }

  public static func export(_ report: LedgerReport, to url: URL) throws {
    let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    guard url.isFileURL, !url.path.isEmpty, !isDirectory else { throw Error.invalidDestination }
    let lines = report.accessibleTable.split(separator: "\n", omittingEmptySubsequences: false)
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
