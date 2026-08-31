import Foundation
import LedgerCore
import LedgerAtlasMacUI
import Testing

@Test func pdfStatementExportWritesAReadablePDF() throws {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "ledger-atlas-statement-\(UUID().uuidString).pdf")
  defer { try? FileManager.default.removeItem(at: url) }
  let report = LedgerReport(
    title: "Activity by kind",
    rows: [LedgerReportRow(id: "expense", label: "expense", amountLiteral: "12.30", unitCode: "USD", count: 1)],
    totalLiteral: "12.30", unitCode: "USD")
  try LedgerPDFStatementExporter.export(report, to: url)
  let bytes = try Data(contentsOf: url)
  #expect(bytes.starts(with: Data("%PDF".utf8)))
  #expect(bytes.contains(Data("%%EOF".utf8)))
}
