import AppKit
import LedgerCore
import SwiftUI
import UniformTypeIdentifiers

/// The rows the ledger view shows right now, ready to save as CSV (#170). The ledger view
/// publishes it while it is in front; File > Export > CSV saves it.
struct LedgerViewCSV: Sendable {
  /// "daily", "calendar", …, for the suggested file name.
  let modeName: String
  /// Builds the file from the view's current mode and filter.
  let data: @Sendable () -> Data
}

extension FocusedValues {
  @Entry var ledgerViewCSV: LedgerViewCSV?
}

/// File > Export > CSV of This View… It is enabled only while a ledger view is in front.
public struct LedgerViewExportCommands: Commands {
  @FocusedValue(\.ledgerViewCSV) private var csv

  public init() {}

  public var body: some Commands {
    CommandGroup(replacing: .importExport) {
      Menu("Export") {
        Button("CSV of This View…") {
          if let csv { Self.save(csv) }
        }
        .disabled(csv == nil)
      }
    }
  }

  static let csvType = UTType(filenameExtension: "csv") ?? .commaSeparatedText

  /// Asks before a plaintext copy is written (as every export does), then writes only the
  /// file the person picked.
  @MainActor
  static func save(_ csv: LedgerViewCSV) {
    let warning = NSAlert()
    warning.alertStyle = .warning
    warning.messageText = LedgerJourney.plaintextExportWarning.title
    warning.informativeText = LedgerJourney.plaintextExportWarning.message
    warning.addButton(withTitle: "Continue")
    warning.addButton(withTitle: "Cancel")
    guard warning.runModal() == .alertFirstButtonReturn else { return }

    let panel = NSSavePanel()
    panel.title = "Export CSV"
    panel.prompt = "Export"
    panel.allowedContentTypes = [csvType]
    panel.nameFieldStringValue = "ledger-atlas-\(csv.modeName).csv"
    panel.message = "The rows this view shows, with its filters, in the same order."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try SavedFile.write(csv.data(), to: url, replacing: true)
    } catch {
      let failure = NSAlert()
      failure.alertStyle = .warning
      failure.messageText = "The CSV file could not be saved."
      failure.informativeText = "Choose another place and try again."
      failure.runModal()
    }
  }
}
